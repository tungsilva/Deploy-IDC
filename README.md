# Bizfly Server Monitor — chạy bằng Docker

Chỉ cần Docker (Engine 24+ và plugin `docker compose` v2). Không cần mã nguồn, không build gì.

## Cài đặt

```bash
git clone https://github.com/tungsilva/Deploy-IDC.git monitor
cd monitor
cp .env.example .env

# sinh mọi mật khẩu/khoá còn trống
for k in POSTGRES_PASSWORD REDIS_PASSWORD JWT_SECRET BMC_CREDENTIALS_ENCRYPTION_KEY ADMIN_PASSWORD; do
  sed -i "s|^$k=$|$k=$(openssl rand -hex 32)|" .env; done

# sửa trong .env: CORE_EXTERNAL_HOST (IP máy này), CERT_EXTRA_SANS, ADMIN_EMAIL
nano .env

docker compose up -d
```

Image để public trên Docker Hub (`tungsilva10/monitor-hardware-*`), nên không cần `docker login`.

Mở `https://<CORE_EXTERNAL_HOST>:8443/`. Đăng nhập bằng `ADMIN_EMAIL` và `ADMIN_PASSWORD` trong `.env`.

Lần đầu `up`, compose tự làm hết: kéo image → sinh chứng chỉ TLS (`certs`) → dựng CSDL và tạo tài khoản quản trị (`migrate`) → phát runtime cho worker node (`runtime`) → chạy api, worker, ml, web.

**Sao lưu ngay** `.env` và khoá CA: `docker compose run --rm certs cat /ca/ca.key > ca.key.backup`.
- Mất `BMC_CREDENTIALS_ENCRYPTION_KEY` là mất mọi mật khẩu BMC/ESXi đã lưu.
- Mất khoá CA là phải cài lại mọi agent.

## Sửa cấu hình

- **Mọi tuỳ chỉnh thường gặp nằm trong `.env`**: cổng, bind address, cỡ máy, số worker, thời gian lưu dữ liệu. Sửa xong thì `docker compose up -d`.
- **Thứ `.env` không có** (thêm volume, đổi giới hạn bộ nhớ…): đừng sửa `docker-compose.yml`. Tạo `docker-compose.override.yml` cạnh nó — compose tự gộp hai tệp, còn git bỏ qua tệp override nên `git pull` về sau không bị xung đột. Ví dụ:
  ```yaml
  services:
    worker:
      deploy:
        resources:
          limits: { memory: 2g }
  ```
- `.env` không bao giờ bị commit (đã có trong `.gitignore`).

## Nâng cấp

```bash
docker compose exec postgres sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > backup-$(date +%F).dump
git pull                                                          # docker-compose.yml mới, nếu có
sed -i "s/^MH_VERSION=.*/$(grep '^MH_VERSION=' .env.example)/" .env   # lấy số bản mới nhất
docker compose up -d
```

Hoặc ghim một bản cụ thể: `sed -i 's/^MH_VERSION=.*/MH_VERSION=2026.11.05.1/' .env`.

Compose kéo image bản mới, migrate, rồi chỉ tạo lại các service ứng dụng; postgres và redis giữ nguyên. Worker node tự lên bản mới trong khoảng 2 phút.

Quay về bản cũ: đặt lại `MH_VERSION` cũ rồi `docker compose up -d`. Migrate chỉ thêm bảng/cột, nên bản cũ vẫn chạy được trên CSDL đã nâng.

> Không chạy `docker compose down -v`: cờ `-v` xoá sạch CSDL và chứng chỉ.

## Agent, ESXi, worker node

- **Agent**: mở máy chủ → tab *Overview* → chạy lệnh cài trên máy đó. Hỗ trợ Linux có Python 3.5+ (Ubuntu 16.04→24.04, CentOS/Rocky/Alma 7–9) và Windows Server 2016+.
- **VMware ESXi**: không cài gì lên host. Dùng thẻ *VMware ESXi (vSphere API)* ở tab *Overview*.
- **Worker node** ở site khác:
  1. Trong `.env`, đặt `POSTGRES_BIND_ADDRESS` và `REDIS_BIND_ADDRESS` bằng IP mạng riêng của máy này, rồi `docker compose up -d`. Postgres và Redis khởi động lại vài giây.
  2. Vào *Worker Groups* → thêm node → chạy lệnh cài trên node.
  3. Chỉ mở cổng 3000/5432/6379 cho IP các node: `sudo COMPOSE_DIR=$PWD bash firewall/sync-worker-firewall.sh`. Nên đặt chạy định kỳ.

## Công cụ agent (HDSentinel, StorCLI, SMCIPMITool)

Ba công cụ này của hãng thứ ba có giấy phép riêng, nên **không nằm trong image** (image để public). Site mới bắt đầu với kho công cụ trống. Có hai cách nạp:

- **Tải lên qua giao diện**: *Servers → Agent Tools*.
- **Chép nguyên kho từ site cũ** (khoảng 220 MB). Gửi tệp này qua kênh riêng, không đưa lên Docker Hub:
  ```bash
  # trên site cũ (cùng thư mục với docker-compose.yml của site đó)
  docker compose run --rm --no-deps -v "$PWD":/out --entrypoint sh api -c 'tar czf /out/agent-tools.tgz -C /data/agent-tools .'
  # trên site mới
  docker compose run --rm --no-deps -v "$PWD":/in --entrypoint sh api -c 'tar xzf /in/agent-tools.tgz -C /data/agent-tools'
  ```

Worker node tự đồng bộ công cụ từ Core. Còn MegaCLI do agent tự tải từ Broadcom, và smartmontools/mdadm lấy từ kho gói của hệ điều hành.

Thiếu công cụ nào thì mất phần dữ liệu tương ứng:

| Công cụ | Thiếu thì |
|---|---|
| HDSentinel | Không có "số ngày còn lại" của ổ đĩa; SMART qua smartctl vẫn có. |
| StorCLI | Không có dữ liệu RAID LSI/Dell trên máy không tải được MegaCLI. |
| SMCIPMITool | Máy Supermicro đặt giao thức SMCIPMI không poll được; chuyển sang Redfish/IPMI. |

## Những gì KHÔNG nằm trong image

| Thứ | Ở site mới |
|---|---|
| Dữ liệu và cấu hình nhập trên giao diện: tài khoản, máy chủ và mật khẩu BMC, luật cảnh báo đã sửa, SMTP/Telegram/webhook, báo cáo định kỳ, IDC/tầng/tủ rack, nhóm máy, phân quyền | Tạo lại trên giao diện, **hoặc** chuyển CSDL cũ sang (xem mục Khôi phục) kèm đúng `BMC_CREDENTIALS_ENCRYPTION_KEY` cũ |
| Công cụ agent (HDSentinel, StorCLI, SMCIPMITool) | Tải lên qua *Servers → Agent Tools*, hoặc chép kho (mục trên) |
| Agent đã cài trên máy chủ, worker node đã cài | Vẫn trỏ về Core cũ và tin CA cũ → cài lại bằng lệnh của site mới |
| Firewall cho worker node | Chạy `firewall/sync-worker-firewall.sh` bằng root, đặt chạy định kỳ (systemd timer hoặc cron) |
| Siết `pg_hba` (Postgres chỉ nhận IP worker) | Mặc định Postgres nhận mọi IP có mật khẩu; được che bởi bind address, firewall và mật khẩu ngẫu nhiên |
| Trình duyệt tin chứng chỉ | CA tự sinh nên trình duyệt sẽ cảnh báo. Nhập `ca.crt` vào máy người dùng, hoặc đặt chứng chỉ thật vào volume `certs` |
| Đồng bộ giờ (NTP), Docker, mạng ra Internet (Docker Hub, MegaCLI) | Chuẩn bị trên máy host |

## Cỡ máy

| Quy mô | Máy Core | Thêm vào `.env` |
|---|---|---|
| ≤ 200 máy chủ | 8 vCPU, 16 GB, SSD 100 GB | (mặc định) |
| ~1000 | 16 vCPU, 64 GB, NVMe 500 GB | `PG_SHARED_BUFFERS=16GB` `PG_EFFECTIVE_CACHE_SIZE=40GB` `PG_SHM_SIZE=4g` `WORKER_REPLICAS=10` |
| ~2500 | 32 vCPU, 128 GB, NVMe 1 TB | `PG_SHARED_BUFFERS=32GB` `PG_EFFECTIVE_CACHE_SIZE=80GB` `PG_WORK_MEM=32MB` `PG_MAINTENANCE_WORK_MEM=2GB` `PG_MAX_WAL_SIZE=32GB` `PG_SHM_SIZE=8g` `WORKER_REPLICAS=12` `WORKER_CONCURRENCY=80` `WORKER_RATE_LIMIT_PER_SECOND=300` `DB_POOL_MAX=12` `AGENT_ALERTS_CONCURRENCY=20` |

## Khôi phục từ bản sao lưu

TimescaleDB cần hai bước *pre/post restore*:

```bash
docker compose stop api worker ml web
docker compose exec -T postgres sh -c 'dropdb -U "$POSTGRES_USER" "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS timescaledb; SELECT timescaledb_pre_restore();"'
docker compose exec -T postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner' < backup-YYYY-MM-DD.dump
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT timescaledb_post_restore();"'
docker compose up -d
```

## Phát hành image (cho người phát triển)

Trên máy có mã nguồn (không phải repo này — repo này chỉ chứa phần triển khai):

```bash
cp docker/release.env.example docker/release.env   # REGISTRY=docker.io/<tổ-chức>  (KHÔNG có / cuối)
docker login                                        # token có quyền Read & Write
./scripts/release.sh                                # test → build → soát bí mật → đẩy :<phiên-bản> và :latest
```

Mỗi phiên bản (`YYYY.MM.DD.N`) chỉ phát hành một lần; script từ chối đẩy đè một số đã có.
