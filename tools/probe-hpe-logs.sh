#!/usr/bin/env bash
# Dò vì sao một máy KHÔNG có dòng SEL/IML nào và KHÔNG có RAID. Viết cho HPE
# (iLO), dùng được cho mọi máy Redfish — Supermicro, Dell.
#
# Đi ĐÚNG đường worker đi, từng chặng, và in ra chặng nào rơi dữ liệu:
#   1. Hệ thống đang lưu gì cho máy này (sel_events theo nguồn, raid_*).
#   2. Systems/1/LogServices → IML → Entries (phân trang như worker: tối đa
#      30 trang / 250 dòng mỗi log): số dòng, dòng có nội dung hay chỉ là
#      link trần, thứ tự cũ→mới, Class HPE (19 = lưu trữ → tab RAID Events),
#      thời gian từng lệnh GET (worker hết giờ ở 10 giây).
#   3. Managers/1/LogServices (IEL bị worker bỏ có chủ ý — chỉ liệt kê).
#   4. Systems/1/Storage và SmartStorage/ArrayControllers → ổ / ổ logic.
#
# Chạy trên máy CORE (thư mục Deploy-IDC hoặc ~/monitor):
#
#   sudo bash tools/probe-hpe-logs.sh <IP-BMC hoặc tên máy>
#
# - Dùng tài khoản BMC ĐÃ LƯU, giải mã ngay trong container worker. Mật khẩu
#   KHÔNG hiện ra, KHÔNG ghi vào báo cáo, không nằm trên dòng lệnh.
# - CHỈ GỬI GET, tuần tự, mỗi lệnh một kết nối mới. Dừng ngay ở 401 đầu
#   tiên để không khoá tài khoản. Tối đa 120 lệnh GET.
#
# Kết quả in ra màn hình và lưu vào ./hpe-logs-<máy>-<thời-gian>.txt
set -uo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ] || ! [[ "$TARGET" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "Cách dùng: sudo bash $0 <IP-BMC hoặc tên máy>   (ví dụ: sudo bash $0 SVR220108NTC)" >&2
  exit 2
fi
if ! docker ps >/dev/null 2>&1; then
  echo "Không gọi được docker — chạy lại bằng sudo." >&2
  exit 1
fi

WORKER=$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /monitor-hardware-worker/ {print $1; exit}')
[ -z "$WORKER" ] && WORKER=$(docker ps --format '{{.Names}}' | grep -m1 -i worker || true)
if [ -z "$WORKER" ]; then
  echo "KHÔNG tìm thấy container worker trên máy này." >&2
  exit 1
fi

OUT="hpe-logs-${TARGET}-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee -a "$OUT") 2>&1
echo "Thời điểm: $(date -Is)   Máy chạy: $(hostname)   Worker: $WORKER"

docker exec -i -w /app -e PROBE_TARGET="$TARGET" "$WORKER" node - <<'JS'
const { Client } = require('pg');
const crypto = require('crypto');
const https = require('https');

const MAX_GETS = 120;
// Cùng con số với worker (redfish-log.service.ts / redfish-client.util.ts).
const WORKER_TIMEOUT_MS = 10000;
const MAX_PAGES = 30;
const MAX_ENTRIES_PER_SERVICE = 250;
const MAX_LOG_SERVICES = 4;
const AUDIT_IDS = new Set(['iel', 'sl', 'auditlog', 'securitylog', 'sessionlog', 'managerlog', 'bmclog']);

(async () => {
  const env = process.env;
  if (!env.POSTGRES_HOST || !env.BMC_CREDENTIALS_ENCRYPTION_KEY) {
    console.log('Container worker này không có CSDL/khoá giải mã (worker node). Chạy script trên máy CORE.');
    return;
  }
  const db = new Client({ host: env.POSTGRES_HOST, port: +env.POSTGRES_PORT, user: env.POSTGRES_USER, password: env.POSTGRES_PASSWORD, database: env.POSTGRES_DB });
  await db.connect();
  const t = env.PROBE_TARGET;
  const { rows } = await db.query(
    `SELECT s.id, s.name, s.vendor, s.model, s."bmcIp", s."bmcProtocol", s."raidDevice", s.status,
            s."bmcFirmwareVersion" fw, s."lastPolledAt", s."consecutiveFailures", s."selPollIntervalSeconds",
            s."sensorPollIntervalSeconds", s."redfishComplementAt",
            s."bmcUsername", s."bmcPasswordCiphertext" c, s."bmcPasswordIv" iv, s."bmcPasswordTag" tag
       FROM servers s WHERE s."bmcIp" = $1 OR s.name = $1 LIMIT 2`, [t]);
  if (rows.length !== 1) { console.log(rows.length ? `Có ${rows.length} máy khớp "${t}" — dùng IP BMC.` : `Không có máy nào khớp "${t}".`); await db.end(); return; }
  const s = rows[0];
  const iso = (d) => (d ? new Date(d).toISOString().slice(0, 19) + 'Z' : '-');
  console.log(`\n== Máy: ${s.name}  vendor=${s.vendor}  model=${s.model ?? '-'}  BMC=${s.bmcIp}  protocol=${s.bmcProtocol}  fw=${s.fw ?? '-'}`);
  console.log(`   status=${s.status}  lỗi liên tiếp=${s.consecutiveFailures}  poll gần nhất=${iso(s.lastPolledAt)}  raidDevice=${s.raidDevice ?? '-'}`);
  console.log(`   chu kỳ sensor=${s.sensorPollIntervalSeconds}s  SEL=${s.selPollIntervalSeconds}s  inventory 15p gần nhất=${iso(s.redfishComplementAt)}`);

  const q = async (sql) => (await db.query(sql, [s.id]).catch((e) => ({ rows: [{ lỗi: e.message }] }))).rows;
  console.log('\n== Đang lưu trong hệ thống');
  for (const r of await q(`SELECT "logSource", count(*)::int n, max("eventTimestamp") newest_event, max("createdAt") last_ingest
                             FROM sel_events WHERE "serverId"=$1 GROUP BY 1 ORDER BY 1`))
    console.log(`   sel_events[${r.logSource}]: ${r.n} dòng, sự kiện mới nhất ${iso(r.newest_event)}, nạp gần nhất ${iso(r.last_ingest)}`);
  const [re] = await q(`SELECT count(*)::int n, max("eventTime") newest FROM raid_event WHERE "serverId"=$1`);
  const [pd] = await q(`SELECT count(*)::int n, string_agg(DISTINCT source, ',') src, max("updatedAt") upd FROM raid_physical_drive WHERE "serverId"=$1`);
  const [vd] = await q(`SELECT count(*)::int n, max("updatedAt") upd FROM raid_virtual_drive WHERE "serverId"=$1`);
  console.log(`   raid_event: ${re.n} dòng (mới nhất ${iso(re.newest)})`);
  console.log(`   raid_physical_drive: ${pd.n} ổ (nguồn ${pd.src ?? '-'}, cập nhật ${iso(pd.upd)})`);
  console.log(`   raid_virtual_drive: ${vd.n} ổ logic (cập nhật ${iso(vd.upd)})`);
  await db.end();

  const d = crypto.createDecipheriv('aes-256-gcm', Buffer.from(env.BMC_CREDENTIALS_ENCRYPTION_KEY, 'hex'), s.iv);
  d.setAuthTag(s.tag);
  const auth = 'Basic ' + Buffer.from(`${s.bmcUsername}:${Buffer.concat([d.update(s.c), d.final()]).toString('utf8')}`).toString('base64');
  const agent = new https.Agent({ rejectUnauthorized: false, keepAlive: false });

  let gets = 0, stop = '';
  const get = (p) => new Promise((res) => {
    if (stop || gets >= MAX_GETS) return res({ status: 'SKIP', ms: 0 });
    gets++;
    const t0 = Date.now();
    const r = https.request({ host: s.bmcIp, path: p, agent, headers: { authorization: auth, accept: 'application/json' }, timeout: 30000 }, (rs) => {
      let b = ''; rs.on('data', (c) => (b += c));
      rs.on('end', () => {
        if (rs.statusCode === 401) stop = '401 — tài khoản đã lưu bị BMC từ chối; dừng để không khoá tài khoản.';
        let j = null; try { j = JSON.parse(b); } catch {}
        res({ status: rs.statusCode, j, ms: Date.now() - t0, bytes: b.length });
      });
    });
    r.on('error', (e) => res({ status: 'ERR ' + e.message, ms: Date.now() - t0 }));
    r.on('timeout', () => r.destroy(new Error('timeout 30s')));
    r.end();
  });
  const slow = (r) => (r.ms > WORKER_TIMEOUT_MS ? `  !! ${r.ms} ms > ${WORKER_TIMEOUT_MS} ms — worker sẽ HẾT GIỜ ở lệnh này` : '');
  const line = (p, r) => `   GET ${p} -> ${r.status}  ${r.ms} ms${r.bytes ? `  ${Math.round(r.bytes / 1024)} KB` : ''}${slow(r)}`;
  const memberRefs = (j) => (j?.Members ?? []).map((m) => m?.['@odata.id']).filter(Boolean);
  const hpe = (e) => e?.Oem?.Hpe ?? e?.Oem?.Hp;
  // Cùng luật với worker (redfish-log.service.ts): isEmptyLogEntry, MEL của
  // Supermicro, và mô tả worker sẽ dùng (Message ?? Description ?? …) — mô tả
  // rỗng bị tầng nạp XOÁ như rác (sel-noise.filter.ts).
  const hasContent = (e) => !!(e.Message || e.Description || e.MessageId || e.Name || e.Created || e.Severity || e.EntryType);
  const isMel = (e) => /MaintenanceEventLog/i.test(String(e?.Oem?.Supermicro?.['@odata.type'] ?? ''));
  const workerText = (e) => String(e.Message ?? e.Description ?? e.MessageId ?? e.Name ?? '(no message)').trim();
  const droppedAtIngest = (e) => ['', '(no message)'].includes(workerText(e).toLowerCase());

  async function readLogTree(root, label) {
    console.log(`\n== ${label}: ${root}`);
    const col = await get(root);
    console.log(line(root, col));
    const first = memberRefs(col.j)[0];
    if (!first) { console.log('   !! không có member nào'); return; }
    const host = await get(first);
    console.log(line(first, host));
    const lsRef = host.j?.LogServices?.['@odata.id'];
    if (!lsRef) { console.log('   !! resource này KHÔNG có link LogServices'); return; }
    const ls = await get(lsRef);
    console.log(line(lsRef, ls));
    const services = memberRefs(ls.j);
    console.log(`   log service: ${services.map((x) => x.split('/').filter(Boolean).pop()).join(', ') || '(không có)'}`);
    let read = 0;
    for (const ref of services) {
      const id = ref.split('/').filter(Boolean).pop();
      if (AUDIT_IDS.has(id.toLowerCase().replace(/[^a-z0-9]/g, ''))) { console.log(`\n   [${id}] worker BỎ QUA có chủ ý (nhật ký đăng nhập/cấu hình của chính BMC)`); continue; }
      if (read >= MAX_LOG_SERVICES) { console.log(`\n   [${id}] worker không đọc tới (quá ${MAX_LOG_SERVICES} log)`); continue; }
      read++;
      if (stop || gets >= MAX_GETS) break;
      await readService(ref, id);
    }
  }

  async function readService(ref, id) {
    const svc = await get(ref);
    console.log(`\n   [${id}]`);
    console.log(line(ref, svc));
    const j = svc.j ?? {};
    console.log(`     Id=${j.Id ?? '-'}  ServiceEnabled=${j.ServiceEnabled ?? '-'}  MaxNumberOfRecords=${j.MaxNumberOfRecords ?? '-'}  OverWritePolicy=${j.OverWritePolicy ?? '-'}  Health=${j.Status?.Health ?? '-'}`);
    let next = j.Entries?.['@odata.id'];
    if (!next) { console.log('     !! log này KHÔNG có link Entries → worker trả 0 dòng'); return; }
    // Giống worker (từ 2026.11.20.2): log cũ-trước thì đọc tới cuối và giữ
    // 250 dòng MỚI NHẤT; log mới-trước thì dừng khi đủ 250.
    const kept = []; let bare = 0, mel = 0, total = null, pages = 0, lastBare = null, oldestFirst = null;
    const orderKey = (m) => (m.Id !== undefined && m.Id !== '' && Number.isFinite(Number(m.Id)) ? Number(m.Id) : (Date.parse(m.Created) || null));
    while (pages < MAX_PAGES && next && !stop && gets < MAX_GETS) {
      pages++;
      const r = await get(next);
      console.log(line(next, r) + `  members=${r.j?.Members?.length ?? '-'}`);
      if (r.status !== 200 || !r.j) { console.log('     !! trang này lỗi — worker sẽ coi cả lượt là lỗi'); break; }
      if (total === null) total = r.j['Members@odata.count'] ?? null;
      if (oldestFirst === null) {
        const keys = (r.j.Members ?? []).map(orderKey).filter((k) => k !== null);
        if (keys.length >= 2 && keys[0] !== keys.at(-1)) oldestFirst = keys.at(-1) > keys[0];
      }
      for (const m of r.j.Members ?? []) {
        if (isMel(m)) { mel++; continue; }
        if (!hasContent(m)) { bare++; if (Number(String(m['@odata.id']).split('/').pop()) >= Number(String(lastBare ?? '').split('/').pop() || -1)) lastBare = m['@odata.id']; continue; }
        kept.push(m);
      }
      if (!oldestFirst && kept.length >= MAX_ENTRIES_PER_SERVICE) { kept.length = MAX_ENTRIES_PER_SERVICE; console.log(`     (worker dừng ở đây: đủ ${MAX_ENTRIES_PER_SERVICE} dòng)`); break; }
      if (oldestFirst && kept.length > MAX_ENTRIES_PER_SERVICE) kept.splice(0, kept.length - MAX_ENTRIES_PER_SERVICE);
      next = r.j['Members@odata.nextLink'];
    }
    console.log(`     thứ tự của BMC: ${oldestFirst === null ? 'không xác định' : oldestFirst ? 'CŨ-TRƯỚC (worker giữ 250 dòng cuối)' : 'mới-trước (worker giữ 250 dòng đầu)'}`);
    if (next && pages >= MAX_PAGES) console.log(`     (worker dừng ở ${MAX_PAGES} trang, log còn nữa)`);
    console.log(`     Members@odata.count=${total ?? '-'}  trang đã đọc=${pages}  dòng có nội dung=${kept.length}  member TRẦN (chỉ @odata.id)=${bare}  MEL Supermicro (worker bỏ)=${mel}`);
    const emptyText = kept.filter(droppedAtIngest).length;
    if (emptyText > 0) console.log(`     !! ${emptyText}/${kept.length} dòng có mô tả RỖNG theo cách worker đọc — tầng nạp XOÁ như rác.`);
    if (bare > 0) {
      console.log(`     !! ${bare} member trần (chỉ có link). Worker từ 2026.11.23 GET riêng tối đa 30 dòng CHƯA LƯU mỗi lượt, mới nhất trước; bản cũ hơn BỎ hết → 0 dòng.`);
      const one = await get(lastBare);
      console.log(line(lastBare, one));
      if (one.j) {
        console.log(`     dòng trần MỚI NHẤT khi GET riêng: Created=${one.j.Created ?? '-'} Severity=${one.j.Severity ?? '-'} EntryCode=${one.j.EntryCode ?? '-'} Message=${String(one.j.Message ?? '').slice(0, 120)}`);
        console.log(`     JSON thô: ${JSON.stringify(one.j).slice(0, 900)}`);
      }
    }
    if (kept.length === 0) return;
    const created = kept.map((e) => e.Created).filter(Boolean);
    console.log(`     thứ tự: dòng đầu Id=${kept[0].Id} ${kept[0].Created ?? '-'}  →  dòng cuối Id=${kept.at(-1).Id} ${kept.at(-1).Created ?? '-'}`);
    if (created.length) console.log(`     cũ nhất ${created.reduce((a, b) => (a < b ? a : b))}   mới nhất ${created.reduce((a, b) => (a > b ? a : b))}`);
    const count = (f) => Object.entries(kept.reduce((m, e) => ((m[f(e)] = (m[f(e)] ?? 0) + 1), m), {})).map(([k, v]) => `${k}:${v}`).join('  ');
    console.log(`     Severity: ${count((e) => e.Severity ?? '(none)')}`);
    if (kept.some((e) => hpe(e))) {
      console.log(`     HPE Class: ${count((e) => hpe(e)?.Class ?? '-')}   (19 = lưu trữ → raid_event)`);
    }
    const newest = [...kept].sort((a, b) => String(b.Created ?? '').localeCompare(String(a.Created ?? ''))).slice(0, 5);
    console.log('     5 dòng mới nhất:');
    for (const e of newest) console.log(`       #${e.Id} ${e.Created ?? '-'} ${e.Severity ?? '-'} ${hpe(e) ? `[${hpe(e).Class}/${hpe(e).Code}] ` : ''}${workerText(e).slice(0, 140) || '(RỖNG)'}`);
    // Nguyên văn một dòng (log sự kiện không chứa mật khẩu) — để thấy hãng đặt
    // nội dung vào trường nào khi Message trống.
    console.log(`     JSON thô dòng mới nhất: ${JSON.stringify(newest[0]).slice(0, 900)}`);
  }

  const ping = await get('/redfish/v1');
  if (ping.status !== 200) {
    console.log(`\n!! Không vào được Redfish của BMC (${ping.status}, ${ping.ms} ms). Máy do worker node quét thì chạy script trên node đó; còn không thì kiểm mạng/BMC trước (tools/diagnose-bmc.sh).`);
    if (stop) console.log('!! ' + stop);
    return;
  }
  console.log(`\nRedfish ${ping.j?.RedfishVersion ?? '-'}  ${ping.j?.Oem?.Hpe?.Manager?.[0]?.ManagerType ?? ping.j?.Oem?.Hp?.Manager?.[0]?.ManagerType ?? ''} ${ping.j?.Oem?.Hpe?.Manager?.[0]?.ManagerFirmwareVersion ?? ping.j?.Oem?.Hp?.Manager?.[0]?.ManagerFirmwareVersion ?? ''}  (${ping.ms} ms)`);

  await readLogTree('/redfish/v1/Systems', 'Log ở cây Systems (IML nằm ở đây)');
  await readLogTree('/redfish/v1/Managers', 'Log ở cây Managers');

  console.log('\n== Lưu trữ');
  const sys = memberRefs((await get('/redfish/v1/Systems')).j)[0] ?? '/redfish/v1/Systems/1';
  const st = await get(`${sys}/Storage`);
  console.log(line(`${sys}/Storage`, st) + `  members=${st.j?.Members?.length ?? '-'}`);
  for (const ref of memberRefs(st.j).slice(0, 4)) {
    const c = await get(ref);
    console.log(line(ref, c) + `  Drives=${c.j?.Drives?.length ?? '-'}  Volumes=${c.j?.Volumes?.['@odata.id'] ? 'có' : '-'}  ${c.j?.StorageControllers?.[0]?.Model ?? c.j?.Name ?? ''}`);
  }
  const ac = await get(`${sys}/SmartStorage/ArrayControllers`);
  console.log(line(`${sys}/SmartStorage/ArrayControllers`, ac) + `  members=${ac.j?.Members?.length ?? '-'}`);
  for (const ref of memberRefs(ac.j).slice(0, 4)) {
    const c = await get(ref);
    console.log(line(ref, c) + `  ${c.j?.Model ?? ''} ${c.j?.Location ?? ''} Health=${c.j?.Status?.Health ?? '-'}`);
    for (const sub of ['DiskDrives', 'UnconfiguredDrives', 'LogicalDrives']) {
      const l = await get(`${ref}/${sub}`);
      console.log(line(`${ref}/${sub}`, l) + `  members=${l.j?.Members?.length ?? '-'}`);
    }
  }

  if (stop) console.log('\n!! ' + stop);
  console.log(`\n== Xong: ${gets} lệnh GET.`);
})().catch((e) => console.log('LỖI:', e.message));
JS
echo
echo "Đã lưu báo cáo: $OUT  — gửi nội dung file này để phân tích."
