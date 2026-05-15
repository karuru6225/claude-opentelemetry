#!/bin/bash
# S3 から Docker ボリュームをリストアする
# Usage: restore.sh <s3-bucket> [timestamp]
#   timestamp 省略時は latest.txt の値を使用
set -euo pipefail

BUCKET="$1"
TIMESTAMP="${2:-}"
PROJECT="claude-monitoring"
VOLUMES=(prometheus_data loki_data grafana_data)

# タイムスタンプが省略された場合は latest.txt から取得
if [ -z "$TIMESTAMP" ]; then
  TIMESTAMP=$(aws s3 cp "s3://${BUCKET}/volumes/latest.txt" - 2>/dev/null || true)
  if [ -z "$TIMESTAMP" ]; then
    echo "ERROR: No backup found in s3://${BUCKET}/volumes/latest.txt"
    echo "       Specify timestamp explicitly: restore.sh <bucket> <timestamp>"
    exit 1
  fi
fi

echo "==> Restoring from: ${TIMESTAMP}"

cd /opt/claude-monitoring

echo "==> Stopping and removing containers..."
docker compose down 2>/dev/null || true

echo "==> Restoring volumes..."
for VOL in "${VOLUMES[@]}"; do
  echo "  - ${VOL}"
  aws s3 cp "s3://${BUCKET}/volumes/${TIMESTAMP}/${VOL}.tar.gz" "/tmp/${VOL}.tar.gz"
  docker volume rm "${PROJECT}_${VOL}" 2>/dev/null || true
  docker volume create "${PROJECT}_${VOL}"
  docker run --rm \
    -v "${PROJECT}_${VOL}:/data" \
    -v "/tmp:/backup" \
    alpine sh -c "cd /data && tar xzf /backup/${VOL}.tar.gz"
  rm "/tmp/${VOL}.tar.gz"
done

echo "==> Starting containers..."
docker compose up -d

echo ""
echo "==> Restore complete."
