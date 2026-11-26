#!/usr/bin/env bash
# Pengujian end-to-end via curl:
#   ADMIN_API_KEY="secret" ./tests/test_api.sh https://<EC2_PUBLIC_IP>
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8000}"
ADMIN_KEY="${ADMIN_API_KEY:-dev-admin-key}"
BATCH_ID="batch-test-$(date +%s)"
IDEMP_KEY="idem-$(date +%s)-1"

echo "==> 1. Health check (GET /health)"
curl -skf "$BASE_URL/health" | python3 -m json.tool

echo "==> 2. Create order (POST /batches/$BATCH_ID/orders)"
CREATE_RES=$(curl -sk -w "\n%{http_code}" -X POST "$BASE_URL/batches/$BATCH_ID/orders" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $IDEMP_KEY" \
  -d '{"size":"M","qty":1,"customerName":"Natanael","contact":"081234567890"}')
echo "$CREATE_RES"

echo "==> 3. Idempotency check (POST ulang dengan Idempotency-Key sama)"
curl -sk -o /dev/null -w "HTTP %{http_code}\n" -X POST "$BASE_URL/batches/$BATCH_ID/orders" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $IDEMP_KEY" \
  -d '{"size":"M","qty":1,"customerName":"Natanael","contact":"081234567890"}'

echo "==> 4. Get order detail (GET /batches/$BATCH_ID/orders/$IDEMP_KEY)"
curl -skf "$BASE_URL/batches/$BATCH_ID/orders/$IDEMP_KEY" | python3 -m json.tool

echo "==> 5. Update size (PUT size=L)"
curl -skf -X PUT "$BASE_URL/batches/$BATCH_ID/orders/$IDEMP_KEY" \
  -H "Content-Type: application/json" \
  -d '{"size":"L"}' | python3 -m json.tool

echo "==> 6. Admin update status tanpa X-API-Key (harus 401)"
curl -sk -o /dev/null -w "HTTP %{http_code}\n" -X PUT "$BASE_URL/batches/$BATCH_ID/orders/$IDEMP_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status":"paid"}'

echo "==> 7. Admin update status paid dengan X-API-Key (harus 200)"
curl -skf -X PUT "$BASE_URL/batches/$BATCH_ID/orders/$IDEMP_KEY" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $ADMIN_KEY" \
  -d '{"status":"paid"}' | python3 -m json.tool

echo "==> 8. List orders per batch (GET /batches/$BATCH_ID/orders)"
curl -skf "$BASE_URL/batches/$BATCH_ID/orders" | python3 -m json.tool

echo "==> 9. Cancel order dua kali (pertama 200, kedua 409)"
curl -sk -o /dev/null -w "Cancel #1: HTTP %{http_code}\n" -X DELETE "$BASE_URL/batches/$BATCH_ID/orders/$IDEMP_KEY"
curl -sk -o /dev/null -w "Cancel #2: HTTP %{http_code}\n" -X DELETE "$BASE_URL/batches/$BATCH_ID/orders/$IDEMP_KEY"

echo "==> Semua tes dasar selesai!"

