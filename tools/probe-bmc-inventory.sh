#!/usr/bin/env bash
# Dò xem BMC trả về những gì về CARD (card mạng, card RAID, thiết bị PCIe) —
# để biết vì sao tab Hardware của một máy thiếu card.
#
# Chạy trên máy CORE (thư mục Deploy-IDC):
#
#   sudo bash tools/probe-bmc-inventory.sh <IP-BMC hoặc tên máy>
#
# - Dùng tài khoản BMC ĐÃ LƯU trong hệ thống, giải mã ngay trong container
#   worker. Mật khẩu KHÔNG hiện ra, KHÔNG ghi vào báo cáo, không nằm trên
#   dòng lệnh.
# - CHỈ GỬI GET. Dừng ngay ở lần 401 đầu tiên để không làm khoá tài khoản.
# - Giới hạn 150 lệnh GET, tuần tự, mỗi lệnh một kết nối mới (tránh lỗi
#   keep-alive của một số BMC).
#
# Kết quả in ra màn hình và lưu vào ./bmc-inventory-<máy>-<thời-gian>.txt
set -uo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ] || ! [[ "$TARGET" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "Cách dùng: sudo bash $0 <IP-BMC hoặc tên máy>   (ví dụ: sudo bash $0 SVR1250L-NTC)" >&2
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

OUT="bmc-inventory-${TARGET}-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee -a "$OUT") 2>&1
echo "Thời điểm: $(date -Is)   Máy chạy: $(hostname)   Worker: $WORKER"

docker exec -i -w /app -e PROBE_TARGET="$TARGET" "$WORKER" node - <<'JS'
const { Client } = require('pg');
const crypto = require('crypto');
const https = require('https');

const MAX_GETS = 150;
// Nhánh có thể chứa thông tin card. Bỏ qua nhánh to mà không liên quan.
const WANT = /PCIe|Network|Ethernet|Storage|Adapter|Port|Slot|Function|Oem|Controller/i;
const SKIP = /LogServices|Sensors|Thermal|Power|Memory|Processors|Drives|Volumes|Bios|SecureBoot|Session|Account|EventService|JsonSchemas|Registries|UpdateService|TaskService|CertificateService|\$metadata|odata|Enclosure|SmcNodeManager|VirtualMedia|SerialInterfaces|NetworkProtocol|LogEntry|Assembly/i;
const FIELDS = ['Id', 'Name', 'Description', 'Model', 'Manufacturer', 'PartNumber', 'SerialNumber', 'SKU',
  'FirmwareVersion', 'DeviceType', 'ClassCode', 'VendorId', 'DeviceId', 'MACAddress', 'PermanentMACAddress',
  'SpeedMbps', 'LinkStatus', 'InterfaceEnabled', 'Status', 'SlotType', 'Lanes', 'PCIeType', 'Location', 'RedfishVersion'];

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
    `SELECT s.id, s.name, s.vendor, s."bmcIp", s."bmcProtocol", s."bmcFirmwareVersion", s.motherboard, s.model,
            s."bmcUsername", s."bmcPasswordCiphertext" c, s."bmcPasswordIv" iv, s."bmcPasswordTag" tag,
            wg.name AS worker_group
       FROM servers s LEFT JOIN worker_groups wg ON wg.id = s."workerGroupId"
      WHERE s."bmcIp" = $1 OR s.name = $1 LIMIT 2`, [t]);
  if (rows.length !== 1) { console.log(rows.length ? `Có ${rows.length} máy khớp "${t}" — dùng IP BMC.` : `Không có máy nào khớp "${t}".`); await db.end(); return; }
  const s = rows[0];
  console.log(`\n== Máy: ${s.name}  vendor=${s.vendor}  BMC=${s.bmcIp}  protocol=${s.bmcProtocol}  fw=${s.bmcFirmwareVersion}  board=${s.motherboard ?? '-'}  model=${s.model ?? '-'}`);
  console.log(`   Worker group: ${s.worker_group ?? '(core)'}${s.worker_group ? '  — máy này do worker node quét; nếu bên dưới báo không kết nối được thì chạy trên node đó.' : ''}`);
  const nic = await db.query(`SELECT "portId", "macAddress", "adapterModel", "linkStatus" FROM nic_port WHERE "serverId"=$1 ORDER BY 1`, [s.id]).catch(() => ({ rows: [] }));
  const pcie = await db.query(`SELECT "deviceId", name, model, manufacturer FROM pcie_device WHERE "serverId"=$1 ORDER BY 1`, [s.id]).catch(() => ({ rows: [] }));
  const osIf = await db.query(`SELECT name, "macAddress" FROM os_interface_current WHERE "serverId"=$1 ORDER BY 1`, [s.id]).catch(() => ({ rows: [] }));
  console.log(`   Đã lưu: ${nic.rows.length} cổng (nic_port), ${pcie.rows.length} thiết bị (pcie_device), ${osIf.rows.length} interface từ agent`);
  for (const r of nic.rows) console.log('     cổng ', JSON.stringify(r));
  for (const r of pcie.rows) console.log('     card ', JSON.stringify(r));
  await db.end();

  const d = crypto.createDecipheriv('aes-256-gcm', Buffer.from(env.BMC_CREDENTIALS_ENCRYPTION_KEY, 'hex'), s.iv);
  d.setAuthTag(s.tag);
  const auth = 'Basic ' + Buffer.from(`${s.bmcUsername}:${Buffer.concat([d.update(s.c), d.final()]).toString('utf8')}`).toString('base64');
  const agent = new https.Agent({ rejectUnauthorized: false, keepAlive: false });

  let gets = 0, stop = '';
  const get = (p) => new Promise((res) => {
    if (stop || gets >= MAX_GETS) return res({ status: 'SKIP' });
    gets++;
    const r = https.request({ host: s.bmcIp, path: p, agent, headers: { authorization: auth, accept: 'application/json' }, timeout: 25000 }, (rs) => {
      let b = ''; rs.on('data', (c) => (b += c));
      rs.on('end', () => {
        if (rs.statusCode === 401) stop = '401 — tài khoản đã lưu bị BMC từ chối; dừng để không khoá tài khoản.';
        let j = null; try { j = JSON.parse(b); } catch {}
        res({ status: rs.statusCode, j });
      });
    });
    r.on('error', (e) => res({ status: 'ERR ' + e.message }));
    r.on('timeout', () => r.destroy(new Error('timeout 25s')));
    r.end();
  });

  const brief = (j) => {
    if (!j || typeof j !== 'object') return '';
    const o = {};
    for (const k of FIELDS) if (j[k] !== undefined && j[k] !== null && j[k] !== '') o[k] = j[k];
    if (Array.isArray(j.Members)) o.Members = j.Members.length;
    if (j.Links) o.LinksKeys = Object.keys(j.Links);
    if (j.Oem) o.Oem = JSON.stringify(j.Oem).slice(0, 400);
    if (Array.isArray(j.Controllers)) o.Controllers = JSON.stringify(j.Controllers).slice(0, 500);
    if (Array.isArray(j.StorageControllers)) o.StorageControllers = j.StorageControllers.map((c) => ({ Name: c.Name, Model: c.Model, Manufacturer: c.Manufacturer, Description: c.Description, SerialNumber: c.SerialNumber, FirmwareVersion: c.FirmwareVersion, Health: c.Status?.Health }));
    if (Array.isArray(j.Slots)) o.Slots = j.Slots.map((sl) => ({ type: sl.SlotType, lanes: sl.Lanes, label: sl.Location?.PartLocation?.ServiceLabel, links: sl.Links ? JSON.stringify(sl.Links).slice(0, 200) : undefined }));
    if (Array.isArray(j.NetworkPorts)) o.NetworkPorts = j.NetworkPorts;
    return JSON.stringify(o);
  };
  const childLinks = (j) => {
    const out = new Set();
    const walk = (v, depth) => {
      if (!v || typeof v !== 'object' || depth > 6) return;
      if (Array.isArray(v)) { v.forEach((x) => walk(x, depth + 1)); return; }
      for (const [k, x] of Object.entries(v)) {
        if (k === '@odata.id' && typeof x === 'string' && !x.includes('#')) out.add(x);
        else walk(x, depth + 1);
      }
    };
    walk(j, 0);
    return [...out];
  };

  // Gốc + Systems/Chassis/Managers và mọi thành viên của chúng, rồi lần theo
  // link vào các nhánh có thể chứa card.
  const queue = ['/redfish/v1', '/redfish/v1/Systems', '/redfish/v1/Chassis', '/redfish/v1/Managers'];
  const seen = new Set(queue);
  const topMember = /^\/redfish\/v1\/(Systems|Chassis|Managers)\/[^/]+$/;
  console.log('\n== Cây Redfish (chỉ nhánh liên quan đến card)');
  while (queue.length && !stop && gets < MAX_GETS) {
    const p = queue.shift();
    const r = await get(p);
    if (r.status === 'SKIP') break;
    console.log(`\n${p}  ->  ${r.status}`);
    const line = brief(r.j);
    if (line && line !== '{}') console.log('   ' + line.slice(0, 1500));
    if (r.status !== 200 || !r.j) continue;
    for (const link of childLinks(r.j)) {
      if (seen.has(link) || !link.startsWith('/redfish/v1/')) continue;
      const rel = link.slice(p.length);
      const isMember = link.startsWith(p + '/') && Array.isArray(r.j.Members);
      const ok = topMember.test(link) && !/Managers\/[^/]+$/.test(p)
        || (!SKIP.test(link) && (WANT.test(link) || (isMember && WANT.test(p))));
      if (ok && rel !== '') { seen.add(link); queue.push(link); }
    }
  }
  // Hai đường chuẩn đời mới mà BMC cũ có khi không đặt link tới — hỏi thẳng.
  for (const p of ['/redfish/v1/Systems/1/PCIeDevices', '/redfish/v1/Systems/1/NetworkInterfaces', '/redfish/v1/Chassis/1/NetworkAdapters', '/redfish/v1/Chassis/1/PCIeDevices']) {
    if (seen.has(p) || stop) continue;
    const r = await get(p);
    console.log(`\n${p}  ->  ${r.status}  (hỏi thẳng)`);
    const line = brief(r.j);
    if (line && line !== '{}') console.log('   ' + line.slice(0, 1500));
  }
  if (stop) console.log('\n!! ' + stop);
  console.log(`\n== Xong: ${gets} lệnh GET.`);
})().catch((e) => console.log('LỖI:', e.message));
JS
echo
echo "Đã lưu báo cáo: $OUT  — gửi nội dung file này để phân tích."
