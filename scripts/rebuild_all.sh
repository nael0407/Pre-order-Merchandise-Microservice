#!/usr/bin/env bash
# One-command rebuild seluruh infrastruktur & aplikasi setelah sandbox reset:
#   DB_PASS='Rahasia123!' ADMIN_API_KEY='kunci-admin' ./scripts/rebuild_all.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REGION="${AWS_REGION:-us-east-1}"
DB_USER="${DB_USER:-admin}"
DB_PASS="${DB_PASS:-}"
DB_NAME="${DB_NAME:-merch_preorder}"
KEY_NAME="${KEY_NAME:-merch-preorder-key}"
ADMIN_API_KEY="${ADMIN_API_KEY:-dev-admin-key}"
PO_OPEN="${PO_OPEN:-true}"
PO_QUOTA="${PO_QUOTA:-50}"
PER_PERSON_LIMIT="${PER_PERSON_LIMIT:-2}"
PAY_WINDOW_HOURS="${PAY_WINDOW_HOURS:-24}"

if [[ -z "$DB_PASS" ]]; then
  echo "Error: set DB_PASS terlebih dahulu (contoh: DB_PASS='Rahasia123!' ./scripts/rebuild_all.sh)" >&2
  exit 1
fi

echo "==> [1/5] Provisioning AWS resources di $REGION..."
./scripts/aws_setup.sh

EC2_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=merch-api-server" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$REGION")
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier merch-preorder-db \
  --query 'DBInstances[0].Endpoint.Address' --output text --region "$REGION")

echo "==> [2/5] Menunggu SSH siap di $EC2_IP..."
SSH_OPTS="-i ${KEY_NAME}.pem -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
for _ in $(seq 1 30); do
  if ssh $SSH_OPTS "ubuntu@${EC2_IP}" "true" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

echo "==> [3/5] Membuat .env dan menyalin kode ke EC2..."
cat <<EOF > .env
DB_HOST=$RDS_ENDPOINT
DB_PORT=3306
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_NAME=$DB_NAME
PO_OPEN=$PO_OPEN
PO_QUOTA=$PO_QUOTA
PER_PERSON_LIMIT=$PER_PERSON_LIMIT
PAY_WINDOW_HOURS=$PAY_WINDOW_HOURS
ADMIN_API_KEY=$ADMIN_API_KEY
EOF

ssh $SSH_OPTS "ubuntu@${EC2_IP}" "mkdir -p ~/kompaw"
scp $SSH_OPTS -r requirements.txt sql src nginx scripts tests .env "ubuntu@${EC2_IP}:~/kompaw/"

echo "==> [4/5] Menjalankan bootstrap di EC2 (Python, Schema, Nginx, Systemd, Cron)..."
ssh $SSH_OPTS "ubuntu@${EC2_IP}" "sudo bash ~/kompaw/scripts/ec2_bootstrap.sh"

echo "==> [5/5] Menjalankan uji konektivitas end-to-end..."
ADMIN_API_KEY="$ADMIN_API_KEY" ./tests/test_api.sh "https://${EC2_IP}"

echo ""
echo "=========================================="
echo "REBUILD & VERIFIKASI SELESAI"
echo "Base URL (HTTPS): https://${EC2_IP}"
echo "Base URL (HTTP) : http://${EC2_IP}"
echo "=========================================="

