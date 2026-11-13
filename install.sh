#!/usr/bin/env bash
# Cài đặt / cập nhật Việc Đến trên VPS Ubuntu 22.04/24.04.
#   sudo bash install.sh                      # cài hoặc cập nhật
#   sudo bash install.sh --seed               # cài + nạp dữ liệu demo (XÓA dữ liệu cũ)
#   DOMAIN=viecden.example.vn sudo -E bash install.sh
# Không đụng tới các website/CSDL khác trên VPS: chỉ thêm 1 site reverse proxy, 1 dịch vụ systemd, 1 CSDL riêng.
set -euo pipefail

DOMAIN="${DOMAIN:-viecden.nhavanmon.com.vn}"
REPO="${REPO:-https://github.com/mabenh/Quan-Ly---Giao-Viec.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/viecden}"
APP_USER="${APP_USER:-viecden}"
DB_NAME="${DB_NAME:-viecden}"
DB_USER="${DB_USER:-viecden}"
EMAIL="${EMAIL:-}"            # email nhận thông báo Let's Encrypt (tùy chọn)
SEED=0; [[ "${1:-}" == "--seed" ]] && SEED=1

log() { echo -e "\033[1;34m==> $*\033[0m"; }
die() { echo -e "\033[1;31mLỖI: $*\033[0m" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Hãy chạy bằng sudo"

log "1/8 Gói hệ thống"
apt-get update -qq
apt-get install -y -qq curl git unzip ca-certificates gnupg openssl >/dev/null

log "2/8 Node.js 22"
if ! command -v node >/dev/null || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
node -v

log "3/8 PostgreSQL"
if ! command -v psql >/dev/null; then apt-get install -y -qq postgresql >/dev/null; fi
systemctl enable --now postgresql >/dev/null 2>&1 || true

id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "/home/$APP_USER" --shell /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR" && chown "$APP_USER:$APP_USER" "$APP_DIR"

ENV_FILE="$APP_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  # giữ nguyên mật khẩu/bí mật cũ khi cập nhật
  DB_PASS=$(grep -oP '^DATABASE_URL=postgresql://[^:]+:\K[^@]+' "$ENV_FILE" || true)
  JWT_SECRET=$(grep -oP '^JWT_SECRET=\K.*' "$ENV_FILE" || true)
fi
DB_PASS="${DB_PASS:-$(openssl rand -hex 16)}"
JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 \
  && sudo -u postgres psql -qc "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';" \
  || sudo -u postgres psql -qc "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 \
  || sudo -u postgres psql -qc "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

log "4/8 Lấy mã nguồn ($REPO)"
SRC="$APP_DIR/src"
if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" fetch -q origin "$BRANCH" && git -C "$SRC" reset -q --hard "origin/$BRANCH"
else
  rm -rf "$SRC"; git clone -q --depth 1 -b "$BRANCH" "$REPO" "$SRC"
fi
cd "$SRC"
if [[ ! -f backend/package.json ]]; then
  Z=$(find . -maxdepth 2 -name '*.zip' | head -1)
  [[ -n "$Z" ]] || die "Không thấy thư mục backend hay file .zip mã nguồn trong repo"
  [[ $(find . -maxdepth 2 -name '*.zip' | wc -l) -eq 1 ]] || die "Repo có nhiều hơn 1 file .zip — chỉ giữ 1 file source.zip"
  unzip -q -o "$Z" -d .
fi
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

log "5/8 Build giao diện & backend"
sudo -u "$APP_USER" bash -c "cd '$SRC/mobile-web' && (npm ci --no-audit --no-fund || npm install --no-audit --no-fund) >/dev/null && npm run build >/dev/null"
sudo -u "$APP_USER" bash -c "cd '$SRC/backend' && (npm ci --no-audit --no-fund || npm install --no-audit --no-fund) >/dev/null && npm run build >/dev/null"

# chọn cổng trống (ưu tiên 3000)
PORT=$(grep -oP '^PORT=\K\d+' "$ENV_FILE" 2>/dev/null || true)
if [[ -z "$PORT" ]]; then
  for p in 3000 3100 3200 3300; do ss -ltn "( sport = :$p )" | grep -q ":$p" || { PORT=$p; break; }; done
fi
cat > "$ENV_FILE" <<EOF
DATABASE_URL=postgresql://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME
JWT_SECRET=$JWT_SECRET
PORT=$PORT
UPLOAD_DIR=$APP_DIR/uploads
WEB_DIR=$SRC/mobile-web/dist
PLAN_ACTIVATION=auto
CORS_ORIGIN=https://$DOMAIN,https://localhost,capacitor://localhost,http://localhost
EOF
chmod 600 "$ENV_FILE"; chown "$APP_USER:$APP_USER" "$ENV_FILE"
mkdir -p "$APP_DIR/uploads" && chown "$APP_USER:$APP_USER" "$APP_DIR/uploads"

log "6/8 Dịch vụ systemd viecden (cổng $PORT)"
cat > /etc/systemd/system/viecden.service <<EOF
[Unit]
Description=Viec Den - quan ly & giam sat viec
After=network.target postgresql.service
[Service]
User=$APP_USER
WorkingDirectory=$SRC/backend
EnvironmentFile=$ENV_FILE
ExecStart=$(command -v node) dist/main.js
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
if [[ $SEED -eq 1 ]]; then
  log "Nạp dữ liệu demo (xóa dữ liệu cũ của CSDL $DB_NAME)"
  systemctl stop viecden 2>/dev/null || true
  sudo -u "$APP_USER" bash -c "cd '$SRC/backend' && set -a && . '$ENV_FILE' && set +a && DISABLE_SCHEDULER=true node dist/db/seed.js" | tail -2
fi
systemctl enable viecden >/dev/null 2>&1; systemctl restart viecden
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$PORT/api/v1/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$PORT/api/v1/health" >/dev/null || { journalctl -u viecden -n 40 --no-pager; die "Ứng dụng không khởi động được"; }

log "7/8 Tên miền $DOMAIN + HTTPS"
if systemctl is-active --quiet nginx; then
  cat > /etc/nginx/sites-available/viecden <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 25m;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/viecden /etc/nginx/sites-enabled/viecden
  nginx -t && systemctl reload nginx
  apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
  if [[ -n "$EMAIL" ]]; then CB_MAIL=(-m "$EMAIL"); else CB_MAIL=(--register-unsafely-without-email); fi
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect "${CB_MAIL[@]}" \
    || echo "⚠ Chưa cấp được HTTPS: kiểm tra bản ghi DNS A của $DOMAIN đã trỏ về IP VPS chưa, rồi chạy lại script."
elif systemctl is-active --quiet apache2; then
  die "VPS đang dùng Apache. Hãy cấu hình reverse proxy $DOMAIN -> http://127.0.0.1:$PORT (xem README) — script không tự sửa Apache."
else
  if ! command -v caddy >/dev/null; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq && apt-get install -y -qq caddy >/dev/null
  fi
  touch /etc/caddy/Caddyfile
  sed -i "/# viecden-begin/,/# viecden-end/d" /etc/caddy/Caddyfile
  cat >> /etc/caddy/Caddyfile <<EOF
# viecden-begin
$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT
}
# viecden-end
EOF
  systemctl enable --now caddy >/dev/null 2>&1; systemctl reload caddy || systemctl restart caddy
fi

log "8/8 Kiểm tra"
sleep 3
if curl -fsS "https://$DOMAIN/api/v1/health" >/dev/null 2>&1; then
  echo -e "\033[1;32m✔ Việc Đến đang chạy tại https://$DOMAIN\033[0m"
else
  echo "⚠ Ứng dụng chạy ở cổng $PORT nhưng chưa truy cập được https://$DOMAIN — kiểm tra DNS, tường lửa (mở cổng 80, 443)."
fi
echo "API cho app Android:  https://$DOMAIN/api/v1"
echo "Cập nhật phiên bản mới: sudo bash $SRC/deploy/install.sh"
echo "Xem log:              journalctl -u viecden -f"
