#!/usr/bin/env bash
# Jalankan di dalam EC2 (Ubuntu 24.04) pada root folder repo:
#   sudo bash scripts/ec2_bootstrap.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_USER="${SUDO_USER:-ubuntu}"

if [[ ! -f "$APP_DIR/.env" ]]; then
  echo "Error: buat $APP_DIR/.env terlebih dahulu sebelum menjalankan bootstrap." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$APP_DIR/.env"
set +a

echo "==> 1. Install paket sistem (Python, Nginx, MySQL client, OpenSSL)"
apt-get update -y
apt-get install -y python3-venv python3-pip nginx mysql-client openssl

echo "==> 2. Setup Python virtualenv dan install dependencies"
sudo -u "$APP_USER" python3 -m venv "$APP_DIR/.venv"
sudo -u "$APP_USER" "$APP_DIR/.venv/bin/pip" install --upgrade pip
sudo -u "$APP_USER" "$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"

echo "==> 3. Inisialisasi schema database di RDS MySQL ($DB_HOST)"
mysql -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" -p"$DB_PASS" < "$APP_DIR/sql/schema.sql"

echo "==> 4. Buat self-signed TLS certificate dan konfigurasi Nginx"
if [[ ! -f /etc/ssl/certs/merch-preorder.crt ]]; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/merch-preorder.key \
    -out /etc/ssl/certs/merch-preorder.crt \
    -subj "/CN=merch-preorder"
fi

cp "$APP_DIR/nginx/merch-preorder.conf" /etc/nginx/sites-available/merch-preorder
ln -sf /etc/nginx/sites-available/merch-preorder /etc/nginx/sites-enabled/merch-preorder
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx

echo "==> 5. Buat systemd service untuk FastAPI (uvicorn)"
cat <<EOF > /etc/systemd/system/merch-preorder.service
[Unit]
Description=Merch Pre-order FastAPI Service
After=network.target

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/.venv/bin/uvicorn src.app:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable merch-preorder
systemctl restart merch-preorder

echo "==> 6. Pasang cron job expire_orders.py (tiap 5 menit)"
cat <<EOF > /etc/cron.d/merch-expire-orders
*/5 * * * * $APP_USER cd $APP_DIR && set -a && . $APP_DIR/.env && set +a && $APP_DIR/.venv/bin/python -m src.expire_orders >> /var/log/merch-expire-orders.log 2>&1
EOF
chmod 644 /etc/cron.d/merch-expire-orders
touch /var/log/merch-expire-orders.log
chown "$APP_USER:$APP_USER" /var/log/merch-expire-orders.log

echo "==> Bootstrap selesai. Cek status service:"
systemctl --no-pager status merch-preorder | head -n 12

