#!/usr/bin/env bash
#
# Đồng bộ firewall theo danh sách worker đã đăng ký.
#
# Ý tưởng: nguồn sự thật là bảng `workers` trong CSDL. Thêm một worker ở giao
# diện -> IP của nó vào `workers.ip` -> lần chạy script kế tiếp tự MỞ ba cổng
# dữ liệu cho đúng IP đó và CHẶN mọi IP khác. Xoá worker -> tự đóng. Không ai
# phải sửa iptables bằng tay, và container api KHÔNG được đụng vào firewall
# host (api bị chiếm thì cũng không nắm được firewall).
#
# ── VÌ SAO KHÔNG DÙNG ufw ────────────────────────────────────────────────
# Docker chèn luật iptables riêng cho cổng nó publish, đi VÒNG QUA chain INPUT
# mà ufw quản. `ufw deny 5432` với một cổng Docker publish là vô tác dụng —
# cổng vẫn mở. Chỗ ĐÚNG để lọc lưu lượng tới container là chain DOCKER-USER,
# thứ Docker cam kết xử lý trước luật forward của chính nó. Script này quản
# một chain con MW-WORKER-FW được DOCKER-USER nhảy vào.
#
# ── HAI ĐIỂM AN TOÀN ─────────────────────────────────────────────────────
# 1. Chỉ lọc gói ĐI VÀO TỪ CARD NGOÀI ($LAN_IFACE). Lưu lượng giữa các
#    container (api -> postgres) đi qua bridge của Docker, KHÔNG qua ens18,
#    nên không bao giờ bị chạm — nếu lọc nhầm nó thì cả stack chết. Lưu lượng
#    do chính host sinh ra tới cổng publish cũng không ingress qua ens18 nên
#    cũng an toàn.
# 2. Chỉ đụng ba cổng DỮ LIỆU: 3000 (api), 5432 (postgres), 6379 (redis).
#    8443 (UI cho người) và 22 (SSH) KHÔNG nằm trong tầm — để nguyên.
#
# ── CHỐNG TỰ KHOÁ ────────────────────────────────────────────────────────
# `--clear` gỡ sạch mọi luật của script (khôi phục về mở như cũ). Nếu lỡ tự
# cắt đường, chạy `sudo bash firewall/sync-worker-firewall.sh --clear` từ
# console/KVM là mở lại. SSH (22) và UI (8443) không bao giờ bị script đụng,
# nên tự khoá SSH là điều script này CỐ Ý không làm được.
#
# Dùng:
#   sudo bash firewall/sync-worker-firewall.sh            # đồng bộ một lần
#   sudo bash firewall/sync-worker-firewall.sh --dry-run  # in ra, không áp
#   sudo bash firewall/sync-worker-firewall.sh --clear    # gỡ hết luật của script
#
set -euo pipefail

# ── Cấu hình (đè bằng biến môi trường nếu cần) ───────────────────────────
#
# LAN_IFACE: card mạng mà worker đi vào. KHÔNG ghi cứng "ens18" nữa — trên
# host production khác tên card có thể là eth0/eno1/enp3s0/bond0. Ghim sai tên
# là kiểu hỏng NGUY HIỂM NHẤT: luật "-i ens18" không khớp gói nào, firewall
# âm thầm không chặn gì, mọi cổng mở toang trong khi bạn tưởng đã bảo vệ.
#
# Mặc định: TỰ DÒ card của route mặc định (card hướng ra gateway — gần như
# luôn là card worker đi vào). Nhiều card (LAN + VPN) thì đặt tay, cách nhau
# bằng dấu cách: LAN_IFACE="ens18 wg0".
LAN_IFACE="${LAN_IFACE:-$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1)}' | head -1)}"
GUARDED_PORTS="${GUARDED_PORTS:-3000 5432 6379}"
CHAIN="MW-WORKER-FW"
# Thư mục chứa docker-compose.yml của Core — mặc định là thư mục cha của
# script này (gói triển khai: <gói>/firewall/sync-worker-firewall.sh).
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PG_USER="${PG_USER:-monitor}"
PG_DB="${PG_DB:-monitor_hardware}"
# IP admin cố định được phép truy cập trực tiếp Postgres/Redis (ngoài các
# worker). Để trống nếu chỉ cho worker. Cách nhau bằng dấu cách.
EXTRA_ALLOW="${EXTRA_ALLOW:-}"

DRY_RUN=false
CLEAR=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  --clear)   CLEAR=true ;;
  "")        ;;
  *) echo "Tham số lạ: $1" >&2; exit 1 ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "Cần chạy bằng root (sudo) để sửa iptables." >&2
  exit 1
fi

run() { if $DRY_RUN; then echo "  + $*"; else "$@"; fi; }

# ── Kiểm card mạng TỒN TẠI — biến hỏng-âm-thầm thành lỗi-lớn-tiếng ────────
# Nếu LAN_IFACE trống (không dò được route mặc định) hoặc trỏ tới card không
# có trên host, thì luật DROP sẽ không khớp gì và firewall thành vô dụng mà
# không báo. Thà DỪNG ở đây, bắt người deploy đặt LAN_IFACE cho đúng, còn hơn
# để một firewall giả chạy im lìm.
if [[ -z "${LAN_IFACE// }" ]]; then
  echo "Không xác định được card mạng (LAN_IFACE trống và không dò được route mặc định)." >&2
  echo "Đặt tay: LAN_IFACE=\"<tên card>\" sudo bash $0" >&2
  echo "Xem card đang có: ip -o link show | awk -F': ' '{print \$2}'" >&2
  exit 1
fi
for iface in $LAN_IFACE; do
  if ! ip link show "$iface" >/dev/null 2>&1; then
    echo "Card mạng '$iface' KHÔNG tồn tại trên host này." >&2
    echo "Các card đang có:" >&2
    ip -o link show 2>/dev/null | awk -F': ' '{print "  - "$2}' >&2
    echo "Sửa LAN_IFACE cho đúng rồi chạy lại." >&2
    exit 1
  fi
done

# Gỡ sạch: bỏ jump khỏi DOCKER-USER rồi xoá chain con.
clear_rules() {
  while iptables -C DOCKER-USER -j "$CHAIN" 2>/dev/null; do
    run iptables -D DOCKER-USER -j "$CHAIN"
  done
  if iptables -L "$CHAIN" -n >/dev/null 2>&1; then
    run iptables -F "$CHAIN"
    run iptables -X "$CHAIN"
  fi
}

# Chạy một lệnh psql qua container postgres (không lộ mật khẩu ra host).
psql_q() {
  cd "$COMPOSE_DIR" && docker compose exec -T postgres \
    psql -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null | tr -d '\r'
}

# Ghi nhịp tim về CSDL để web biết host đã áp thật (hoặc bỏ qua / lỗi) lúc nào.
# Thiếu bước này thì trang firewall chỉ hiện "ý định", người dùng tưởng đã được
# chặn kể cả khi systemd timer trên host chưa bật.
report_status() {
  local mode="$1" count="$2" detail="$3"
  $DRY_RUN && return 0
  psql_q "insert into firewall_status (id,\"appliedAt\",mode,iface,\"entryCount\",detail,\"updatedAt\")
          values ('singleton', now(), '$mode', '$LAN_IFACE', $count, '$detail', now())
          on conflict (id) do update set
            \"appliedAt\"=excluded.\"appliedAt\", mode=excluded.mode, iface=excluded.iface,
            \"entryCount\"=excluded.\"entryCount\", detail=excluded.detail, \"updatedAt\"=now()" >/dev/null || true
}

if $CLEAR; then
  clear_rules
  echo "Đã gỡ toàn bộ luật firewall của worker. Ba cổng dữ liệu mở lại như trước."
  report_status "cleared" 0 "da go het luat"
  exit 0
fi

# ── Lấy danh sách IP được phép từ CSDL (nguồn sự thật) ────────────────────
# Đọc qua container postgres — không cần lộ mật khẩu DB ra host.
#

# IP worker (tự động) + mục admin thêm tay trên web (bảng firewall_allow_entries).
# Chỉ nhận IP đơn hoặc CIDR hợp lệ — lọc lại lần nữa ở đây dù DTO đã kiểm, vì
# giá trị rơi thẳng vào iptables.
IP_OR_CIDR='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$'
mapfile -t WORKER_IPS < <(
  psql_q "select ip from workers where ip is not null and ip <> ''" | grep -E "$IP_OR_CIDR" || true
)
mapfile -t MANUAL_IPS < <(
  psql_q "select value from firewall_allow_entries" | grep -E "$IP_OR_CIDR" || true
)

ALLOW=("${WORKER_IPS[@]}" "${MANUAL_IPS[@]}")
for ip in $EXTRA_ALLOW; do ALLOW+=("$ip"); done


if [[ ${#ALLOW[@]} -eq 0 ]]; then
  # KHÔNG áp DROP khi danh sách rỗng — đó gần như luôn là lỗi đọc DB (postgres
  # đang khởi động lại), và chặn sạch ba cổng sẽ tự cắt luôn mọi worker. Thà
  # giữ nguyên trạng thái cũ và báo, còn hơn đóng nhầm cả fleet.
  echo "Không đọc được IP worker nào từ CSDL — GIỮ NGUYÊN firewall, không thay đổi." >&2
  echo "(Nếu thật sự chưa có worker nào, dùng --clear để bỏ luật thay vì để trống.)" >&2
  report_status "skipped-empty" 0 "danh sach rong hoac doc DB loi"
  exit 1
fi

echo "Card ngoài : $LAN_IFACE (tự dò nếu không đặt tay)"
echo "Cổng chặn  : $GUARDED_PORTS"
echo "Cho phép   : ${ALLOW[*]}"

# ── Dựng lại chain con một cách idempotent ───────────────────────────────
# Tạo chain nếu chưa có, đảm bảo DOCKER-USER nhảy vào nó ở ĐẦU, rồi flush và
# nạp lại nội dung. Làm lại nhiều lần cho cùng kết quả.
iptables -L "$CHAIN" -n >/dev/null 2>&1 || run iptables -N "$CHAIN"
iptables -C DOCKER-USER -j "$CHAIN" 2>/dev/null || run iptables -I DOCKER-USER 1 -j "$CHAIN"
run iptables -F "$CHAIN"

# Kết nối ĐANG mở không bị cắt giữa chừng khi nạp lại luật (kể cả khi một IP
# vừa bị gỡ khỏi allowlist — kết nối cũ sống tới khi đóng, kết nối MỚI mới bị
# chặn). Chuẩn mực, và tránh cắt ngang một lượt poll đang chạy.
run iptables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

# Lặp qua TỪNG card ngoài (có thể có nhiều: LAN + VPN). Mỗi card một bộ
# allow-rồi-DROP riêng, để worker đi vào qua card nào cũng được lọc.
for iface in $LAN_IFACE; do
  for port in $GUARDED_PORTS; do
    for ip in "${ALLOW[@]}"; do
      run iptables -A "$CHAIN" -i "$iface" -s "$ip" -p tcp --dport "$port" -j RETURN
    done
    # Sau mọi IP được phép: chặn phần còn lại tới cổng này, CHỈ khi đến từ card
    # ngoài. RETURN ở trên nghĩa "được — quay lại DOCKER-USER"; tới được DROP
    # này nghĩa là IP không nằm trong danh sách.
    run iptables -A "$CHAIN" -i "$iface" -p tcp --dport "$port" -j DROP
  done
done

echo "Card ngoài đã áp: $LAN_IFACE"
echo "Xong. 8443 (UI) và 22 (SSH) không bị đụng tới."
report_status "applied" "${#ALLOW[@]}" "ok"
