#!/usr/bin/env bash
# Chẩn đoán vì sao hệ thống không nói chuyện được với một BMC (HPE iLO, Dell
# iDRAC...) qua Redfish.
#
# Chạy trên máy core (thư mục Deploy-IDC) — hoặc trên worker node đang quét máy
# đó nếu máy thuộc một worker group:
#
#   sudo bash tools/diagnose-bmc.sh <IP-của-iLO>
#
# Script hỏi tài khoản iLO. Để trống thì bỏ qua các phép thử cần đăng nhập.
# Mật khẩu chỉ được chuyển vào container qua stdin, KHÔNG nằm trên dòng lệnh,
# KHÔNG ghi vào báo cáo.
#
# Mọi phép thử mạng/TLS/Redfish chạy BÊN TRONG container worker — cùng mạng,
# cùng Node/OpenSSL, cùng cách gọi mà hệ thống dùng khi quét — nên kết quả
# phản ánh đúng thứ hệ thống thấy, không phải thứ máy host thấy.
#
# Kết quả in ra màn hình và lưu vào ./bmc-diag-<ip>-<thời-gian>.txt
set -uo pipefail

IP="${1:-}"
if [ -z "$IP" ] || ! [[ "$IP" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "Cách dùng: sudo bash $0 <IP-của-iLO>   (ví dụ: sudo bash $0 192.168.250.31)" >&2
  exit 2
fi

if ! docker ps >/dev/null 2>&1; then
  echo "Không gọi được docker — chạy lại bằng sudo." >&2
  exit 1
fi

OUT="bmc-diag-${IP}-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee -a "$OUT") 2>&1

section() { printf '\n==================== %s ====================\n' "$*"; }

section "0. Môi trường"
echo "Thời điểm : $(date -Is)"
echo "Máy chạy  : $(hostname -f 2>/dev/null || hostname)"
echo "BMC cần xét: $IP"
WORKER=$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /monitor-hardware-worker/ {print $1; exit}')
[ -z "$WORKER" ] && WORKER=$(docker ps --format '{{.Names}}' | grep -m1 -i worker || true)
PG=$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /timescaledb|postgres/ {print $1; exit}')
if [ -z "$WORKER" ]; then
  echo "KHÔNG tìm thấy container worker đang chạy trên máy này. Danh sách container:"
  docker ps --format '  {{.Names}}  {{.Image}}  {{.Status}}'
  exit 1
fi
echo "Container worker: $WORKER ($(docker inspect -f '{{.Config.Image}}' "$WORKER"))"
echo "Container DB    : ${PG:-(không có — đây là worker node, bỏ qua phần CSDL)}"
echo "Số worker đang chạy: $(docker ps --format '{{.Image}}' | grep -c monitor-hardware-worker)"

SERVER_ID=""
if [ -n "$PG" ]; then
  section "1. Hệ thống đang biết gì về máy này (CSDL)"
  # Không chọn cột mật khẩu nào. IP đi qua biến psql (:'ip'), không ghép chuỗi.
  docker exec -i -e IP="$IP" "$PG" sh -c 'psql -X -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ip="$IP" -f -' <<'SQL'
\x on
SELECT s.id, s.name, s.vendor, s."bmcIp", s."bmcProtocol", s."ipmiDriverType",
       s.status, s."consecutiveFailures", s."lastPolledAt", s."lastSeenOkAt",
       s."bmcFirmwareVersion", s."sensorPollIntervalSeconds",
       COALESCE(wg.name, '(core — không thuộc worker group)') AS worker_group
  FROM servers s LEFT JOIN worker_groups wg ON wg.id = s."workerGroupId"
 WHERE s."bmcIp" = :'ip';
\x off
\echo
\echo -- Cảnh báo gần nhất của máy này:
SELECT a.status, a.severity, left(a.title, 90) AS title, a."firstFiredAt", a."lastFiredAt"
  FROM alerts a JOIN servers s ON s.id = a."serverId"
 WHERE s."bmcIp" = :'ip'
 ORDER BY a."firstFiredAt" DESC LIMIT 8;
\echo -- Toàn hệ thống theo hãng / giao thức / trạng thái (lỗi riêng một máy hay cả loạt?):
SELECT vendor, "bmcProtocol", status, count(*) FROM servers GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
SQL
  SERVER_ID=$(docker exec -i -e IP="$IP" "$PG" sh -c 'psql -X -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ip="$IP" -f -' <<'SQL' | head -1
SELECT id FROM servers WHERE "bmcIp" = :'ip' LIMIT 1;
SQL
)
  [ -z "$SERVER_ID" ] && echo ">> Không có máy nào trong hệ thống với BMC IP $IP."
fi

section "2. Lỗi mà chính hệ thống ghi lại (log worker, 6 giờ gần nhất)"
PATTERN="$IP"
[ -n "$SERVER_ID" ] && PATTERN="$IP|$SERVER_ID"
for c in $(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /worker/ {print $1}'); do
  docker logs --since 6h "$c" 2>&1
done | sed 's/\x1b\[[0-9;]*m//g' | grep -E "$PATTERN" | grep -vE "query:|SELECT |INSERT |UPDATE " \
  | sed -E 's/^.*(WARN|ERROR|LOG|DEBUG|VERBOSE) +\[([A-Za-z]+)\] +/\1 [\2] /' \
  | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<id>/g' \
  | cut -c1-260 | sort | uniq -c | sort -rn | head -20
echo "(số đầu dòng = số lần lặp lại)"

section "3. Mạng từ máy host"
ip route get "$IP" 2>/dev/null | head -1 || true
if command -v ping >/dev/null; then ping -c 3 -W 1 "$IP" 2>&1 | tail -2; fi

section "4. Thử trực tiếp từ bên trong worker (mạng + TLS + Redfish + IPMI)"
# Đọc từ terminal; không có terminal (chạy qua ống) thì đọc từ stdin.
if ! { exec 3</dev/tty; } 2>/dev/null; then exec 3<&0; fi
BMC_USER=""
BMC_PASS=""
read -r -u 3 -p "Tài khoản iLO (Enter để bỏ qua phần cần đăng nhập): " BMC_USER || BMC_USER=""
if [ -n "$BMC_USER" ]; then
  read -r -s -u 3 -p "Mật khẩu iLO (không hiện, không ghi vào báo cáo): " BMC_PASS || true
  echo
fi
exec 3<&-
U64=$(printf '%s' "$BMC_USER" | base64 | tr -d '\n')
P64=$(printf '%s' "$BMC_PASS" | base64 | tr -d '\n')
unset BMC_PASS

# Dòng đầu stdin = tài khoản (base64), phần còn lại = mã thử. Không dùng -e/env
# để mật khẩu không hiện trong `ps` hay `docker inspect`.
{
  printf '%s %s\n' "$U64" "$P64"
  cat <<'NODE'
const tls = require('tls'), net = require('net'), https = require('https');
const { constants } = require('crypto');
const { spawn } = require('child_process');
const HOST = process.env.BMC_HOST;
const [u64 = '', p64 = ''] = CREDS.split(' ');
const USER = Buffer.from(u64, 'base64').toString();
const PASS = Buffer.from(p64, 'base64').toString();
const APP_TIMEOUT = 10000; // giới hạn mỗi request của hệ thống (redfish-client.util.ts)
const facts = {};
const log = (s = '') => console.log(s);

// Cấu hình TLS NỚI LỎNG cho firmware cũ: cho TLS 1.0/1.1, mọi bộ mã, và
// renegotiation kiểu cũ (OpenSSL 3 mặc định từ chối — lỗi điển hình của iLO 4).
const RELAXED = {
  minVersion: 'TLSv1',
  ciphers: 'DEFAULT:@SECLEVEL=0',
  secureOptions: constants.SSL_OP_LEGACY_SERVER_CONNECT,
};

function tcp(port) {
  return new Promise((res) => {
    const t = Date.now();
    const s = net.connect({ host: HOST, port, timeout: 5000 });
    s.on('connect', () => { s.destroy(); res({ ok: true, ms: Date.now() - t }); });
    s.on('timeout', () => { s.destroy(); res({ ok: false, err: 'TIMEOUT (5s)', ms: Date.now() - t }); });
    s.on('error', (e) => res({ ok: false, err: `${e.code || ''} ${e.message}`.trim(), ms: Date.now() - t }));
  });
}

function handshake(opts) {
  return new Promise((res) => {
    const t = Date.now();
    const s = tls.connect({ host: HOST, port: 443, rejectUnauthorized: false, timeout: 10000, ...opts });
    s.on('secureConnect', () => {
      const c = s.getPeerCertificate() || {};
      const r = {
        ok: true, ms: Date.now() - t, protocol: s.getProtocol(), cipher: (s.getCipher() || {}).name,
        cert: `CN=${(c.subject || {}).CN || '?'}; issuer=${(c.issuer || {}).CN || '?'}; hết hạn ${c.valid_to || '?'}; khoá ${c.bits || '?'} bit`,
      };
      s.end(); res(r);
    });
    s.on('timeout', () => { s.destroy(); res({ ok: false, err: 'TIMEOUT (10s)', ms: Date.now() - t }); });
    s.on('error', (e) => res({ ok: false, err: `${e.code || ''} ${e.message}`.trim(), ms: Date.now() - t }));
  });
}

function get(path, { auth = false, tlsOpts = {}, timeout = 30000 } = {}) {
  return new Promise((res) => {
    const t = Date.now();
    const headers = { Accept: 'application/json' };
    if (auth) headers.Authorization = 'Basic ' + Buffer.from(`${USER}:${PASS}`).toString('base64');
    const req = https.request(
      { host: HOST, port: 443, path, method: 'GET', headers, rejectUnauthorized: false, agent: false, ...tlsOpts },
      (r) => {
        let body = '';
        r.setEncoding('utf8');
        r.on('data', (d) => { if (body.length < 200000) body += d; });
        r.on('end', () => {
          let json = null;
          try { json = JSON.parse(body); } catch { /* không phải JSON */ }
          res({ status: r.statusCode, ms: Date.now() - t, json, body });
        });
      },
    );
    req.setTimeout(timeout, () => req.destroy(Object.assign(new Error(`không trả lời sau ${timeout / 1000}s`), { code: 'TIMEOUT' })));
    req.on('error', (e) => res({ status: 0, ms: Date.now() - t, err: `${e.code || ''} ${e.message}`.trim() }));
    req.end();
  });
}

function line(label, r) {
  const slow = r.ms > APP_TIMEOUT ? `  <<< CHẬM HƠN GIỚI HẠN ${APP_TIMEOUT / 1000}s CỦA HỆ THỐNG` : '';
  if (r.err) return log(`  ${label.padEnd(46)} LỖI ${r.err} (${r.ms} ms)${slow}`);
  let extra = '';
  if (r.status >= 400) {
    const msg = r.json && r.json.error
      ? JSON.stringify(r.json.error['@Message.ExtendedInfo'] || r.json.error.message || r.json.error).slice(0, 220)
      : (r.body || '').replace(/\s+/g, ' ').slice(0, 160);
    extra = `  → ${msg}`;
  }
  log(`  ${label.padEnd(46)} HTTP ${r.status} (${r.ms} ms)${slow}${extra}`);
}

function ipmi(priv) {
  return new Promise((res) => {
    const args = ['-h', HOST, '-u', USER, '-P', '-D', 'LAN_2_0', '-l', priv, '--session-timeout', '5000', '--retransmission-timeout', '1000'];
    const p = spawn('bmc-info', args);
    let out = '', err = '';
    const kill = setTimeout(() => p.kill('SIGKILL'), 25000);
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (err += d));
    p.on('error', (e) => { clearTimeout(kill); res({ ok: false, err: e.message }); });
    p.on('close', (code) => { clearTimeout(kill); res({ ok: code === 0, out, err: err.replace(/Password:\s*/g, '').trim() }); });
    p.stdin.write(PASS + '\n');
    p.stdin.end();
  });
}

(async () => {
  log('-- 4a. Kết nối TCP');
  for (const port of [443, 80]) {
    const r = await tcp(port);
    facts[`tcp${port}`] = r;
    log(`  cổng ${port}: ${r.ok ? `MỞ (${r.ms} ms)` : `KHÔNG TỚI ĐƯỢC — ${r.err}`}`);
  }

  log('\n-- 4b. Bắt tay TLS');
  const def = await handshake({});
  facts.tlsDefault = def;
  log(`  Cấu hình HIỆN TẠI của hệ thống : ${def.ok ? `OK ${def.protocol} ${def.cipher} (${def.ms} ms)` : `HỎNG — ${def.err}`}`);
  const rel = await handshake(RELAXED);
  facts.tlsRelaxed = rel;
  log(`  Cấu hình nới lỏng (firmware cũ): ${rel.ok ? `OK ${rel.protocol} ${rel.cipher} (${rel.ms} ms)` : `HỎNG — ${rel.err}`}`);
  if (def.ok || rel.ok) log(`  Chứng chỉ: ${(def.ok ? def : rel).cert}`);
  const versions = [];
  for (const v of ['TLSv1', 'TLSv1.1', 'TLSv1.2', 'TLSv1.3']) {
    const r = await handshake({ ...RELAXED, minVersion: v, maxVersion: v });
    versions.push(`${v}=${r.ok ? 'có' : 'không'}`);
  }
  log(`  Phiên bản TLS iLO chấp nhận: ${versions.join(', ')}`);

  const tlsOpts = def.ok ? {} : rel.ok ? RELAXED : null;
  if (!tlsOpts) {
    log('\n  Không bắt tay TLS được bằng cả hai cấu hình — bỏ qua các phép thử Redfish.');
  } else {
    log(`\n-- 4c. Redfish không cần đăng nhập${def.ok ? '' : ' (dùng cấu hình nới lỏng)'}`);
    const root = await get('/redfish/v1/', { tlsOpts });
    facts.root = root;
    line('/redfish/v1/', root);
    if (root.json) {
      const j = root.json;
      const oem = (j.Oem && (j.Oem.Hpe || j.Oem.Hp)) || {};
      const mgr = (oem.Manager && oem.Manager[0]) || {};
      log(`  Vendor=${j.Vendor || '?'}  Product=${j.Product || '?'}  RedfishVersion=${j.RedfishVersion || '?'}`);
      if (mgr.ManagerType || mgr.ManagerFirmwareVersion) {
        log(`  Loại iLO=${mgr.ManagerType || '?'}  Firmware iLO=${mgr.ManagerFirmwareVersion || '?'}  (OEM ${j.Oem.Hpe ? 'Hpe' : 'Hp'})`);
        facts.ilo = `${mgr.ManagerType || ''} ${mgr.ManagerFirmwareVersion || ''}`.trim();
      }
    }

    if (!USER) {
      log('\n-- 4d. Bỏ qua phần cần đăng nhập (không nhập tài khoản).');
    } else {
      log('\n-- 4d. Đi đúng đường quét cảm biến của hệ thống (có đăng nhập)');
      const auth = { auth: true, tlsOpts };
      const chassis = await get('/redfish/v1/Chassis', auth);
      facts.chassis = chassis;
      line('/redfish/v1/Chassis', chassis);
      // Sai tài khoản thì DỪNG mọi phép thử cần đăng nhập: thêm hàng chục lượt
      // đăng nhập hỏng (kể cả qua IPMI) đủ để iLO khoá tài khoản thật.
      facts.authRejected = chassis.status === 401 || chassis.status === 403;
      if (facts.authRejected) {
        log('  → iLO từ chối tài khoản. Dừng các phép thử cần đăng nhập để tránh khoá tài khoản.');
      }
      const members = facts.authRejected
        ? []
        : ((chassis.json && chassis.json.Members) || []).map((m) => m['@odata.id']).filter(Boolean);
      facts.slow = chassis.ms > APP_TIMEOUT;
      for (const ref of members) {
        const c = await get(ref, auth);
        line(ref, c);
        facts.slow = facts.slow || c.ms > APP_TIMEOUT;
        for (const key of ['Thermal', 'Power']) {
          const sub = c.json && c.json[key] && c.json[key]['@odata.id'];
          if (!sub) continue;
          const r = await get(sub, auth);
          line(sub, r);
          facts.slow = facts.slow || r.ms > APP_TIMEOUT;
          if (r.json && key === 'Thermal') log(`      → ${(r.json.Temperatures || []).length} nhiệt độ, ${(r.json.Fans || []).length} quạt`);
          if (r.json && key === 'Power') log(`      → ${(r.json.PowerSupplies || []).length} PSU, ${(r.json.Voltages || []).length} điện áp`);
        }
      }
      if (!facts.authRejected) {
      const managers = await get('/redfish/v1/Managers', auth);
      line('/redfish/v1/Managers', managers);
      const mref = managers.json && managers.json.Members && managers.json.Members[0] && managers.json.Members[0]['@odata.id'];
      if (mref) {
        const m = await get(mref, auth);
        line(mref, m);
        if (m.json) log(`      → Model=${m.json.Model || '?'}  FirmwareVersion=${m.json.FirmwareVersion || '?'}`);
      }
      const systems = await get('/redfish/v1/Systems', auth);
      line('/redfish/v1/Systems', systems);
      const sref = systems.json && systems.json.Members && systems.json.Members[0] && systems.json.Members[0]['@odata.id'];
      if (sref) {
        const s = await get(sref, auth);
        line(sref, s);
        if (s.json) log(`      → Model=${s.json.Model || '?'}  Power=${s.json.PowerState || '?'}  Health=${(s.json.Status || {}).Health || '?'}`);
        const ls = await get(sref.replace(/\/$/, '') + '/LogServices', auth);
        line(sref.replace(/\/$/, '') + '/LogServices', ls);
        if (ls.json) log(`      → ${((ls.json.Members || []).map((x) => (x['@odata.id'] || '').split('/').filter(Boolean).pop())).join(', ')}`);
      }

      log('\n-- 4e. Giữ kết nối (keep-alive): hai request liên tiếp trên CÙNG một kết nối');
      const ka = new https.Agent({ keepAlive: true, rejectUnauthorized: false, ...tlsOpts });
      const k1 = await get('/redfish/v1/Chassis', { ...auth, tlsOpts: { ...tlsOpts, agent: ka } });
      const k2 = await get('/redfish/v1/Chassis', { ...auth, tlsOpts: { ...tlsOpts, agent: ka } });
      line('lần 1', k1);
      line('lần 2 (dùng lại kết nối)', k2);
      facts.keepAliveReset = !k1.err && !!k2.err;
      ka.destroy();

      log('\n-- 4f. 6 kết nối đồng thời (hệ thống chạy nhiều lượt quét song song)');
      const par = await Promise.all(Array.from({ length: 6 }, () => get('/redfish/v1/Chassis', auth)));
      const summary = {};
      for (const r of par) {
        const k = r.err ? r.err.split(' ')[0] : `HTTP ${r.status}`;
        summary[k] = (summary[k] || 0) + 1;
      }
      facts.parallelErrors = par.filter((r) => r.err || r.status >= 500).length;
      log(`  ${Object.entries(summary).map(([k, v]) => `${k} ×${v}`).join(', ')}; chậm nhất ${Math.max(...par.map((r) => r.ms))} ms`);
      }
    }
  }

  if (USER && !facts.authRejected) {
    log('\n-- 4g. IPMI qua LAN (đường dự phòng của hệ thống)');
    let r = await ipmi('ADMIN');
    let priv = 'ADMIN';
    if (!r.ok && /privilege/i.test(r.err)) { r = await ipmi('OPERATOR'); priv = 'OPERATOR'; }
    facts.ipmi = r.ok;
    if (r.ok) {
      const fw = (r.out.match(/Firmware Revision\s*:\s*(.+)/) || [])[1];
      log(`  IPMI (${priv}): OK${fw ? ` — Firmware Revision ${fw.trim()}` : ''}`);
    } else {
      log(`  IPMI (${priv}): HỎNG — ${r.err.split('\n')[0] || 'không rõ'}`);
    }
  }

  log('\n==================== 5. Gợi ý kết luận ====================');
  const t443 = facts.tcp443;
  const found = [];
  if (!t443.ok) {
    if (/ECONNREFUSED/.test(t443.err)) {
      found.push('iLO TỪ CHỐI cổng 443: dịch vụ HTTPS/Redfish trên iLO đang tắt hoặc đổi cổng.');
    } else {
      found.push(`Worker KHÔNG tới được iLO qua mạng (${t443.err}). Kiểm tra định tuyến/VLAN/tường lửa giữa\n  máy này và iLO. Nếu máy thuộc một worker group thì chạy script này trên node của group đó.`);
    }
  } else {
    if (!facts.tlsDefault.ok && facts.tlsRelaxed.ok) {
      found.push(`iLO dùng TLS đời cũ mà Node 20 / OpenSSL 3 mặc định TỪ CHỐI (${facts.tlsDefault.err.split(' ')[0]}).\n  Cần bật chế độ tương thích TLS cho kết nối tới BMC trong hệ thống.`);
    } else if (!facts.tlsDefault.ok) {
      found.push(`Bắt tay TLS hỏng cả khi đã nới lỏng: ${facts.tlsDefault.err}`);
    }
    if (facts.keepAliveReset) found.push('iLO báo giữ kết nối (keep-alive) nhưng RESET khi kết nối được dùng lại → mọi lượt quét hỏng\n  với "socket hang up". Các bản phát hành SAU 2026.11.12.2 tự xử lý (thử lại trên kết nối mới, nhớ BMC đó).');
    if (facts.authRejected) found.push('iLO từ chối tài khoản (401/403): sai mật khẩu, tài khoản bị khoá, hoặc thiếu quyền Login.');
    if (facts.slow) found.push(`iLO trả lời CHẬM hơn giới hạn ${APP_TIMEOUT / 1000}s mỗi request của hệ thống → hệ thống coi là mất kết nối.`);
    if (facts.parallelErrors) found.push('iLO cắt / lỗi khi có nhiều kết nối đồng thời → cần giới hạn số lượt quét song song tới cùng một iLO.');
    if (found.length === 0 && facts.chassis && facts.chassis.status === 200) {
      found.push('Từ worker này iLO trả lời BÌNH THƯỜNG. Xem mục 2 (lỗi thật hệ thống ghi), và kiểm tra máy có\n  thuộc worker group chạy ở node khác không (mục 1, worker_group).');
    }
  }
  if (found.length === 0) found.push('Chưa đủ dữ liệu để kết luận (chưa nhập tài khoản?). Gửi toàn bộ báo cáo để phân tích.');
  for (const f of found) log(`- ${f}`);
})().catch((e) => log(`Lỗi khi chạy phép thử: ${e.stack || e}`));
NODE
} | docker exec -i -e BMC_HOST="$IP" "$WORKER" node -e '
let d = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (d += c)).on("end", () => {
  const i = d.indexOf("\n");
  new Function("require", "CREDS", "process", d.slice(i + 1))(require, d.slice(0, i), process);
});'

unset U64 P64
section "Xong"
echo "Báo cáo đã lưu: $(pwd)/$OUT"
echo "Mật khẩu không có trong báo cáo. Gửi nội dung tệp này lại để phân tích."
