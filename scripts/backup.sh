#!/bin/bash
# Docker ボリュームを S3 にバックアップする
# Usage: backup.sh <s3-bucket>
set -euo pipefail

BUCKET="$1"
TIMESTAMP=$(date -u +%Y-%m-%d_%H%M%S)
PROJECT="claude-monitoring"
VOLUMES=(prometheus_data loki_data grafana_data)

cd /opt/claude-monitoring

# エラー・中断時でも必ずコンテナを再起動する
trap 'echo "==> Starting containers..."; docker compose start' EXIT

echo "==> Stopping containers..."
docker compose stop

echo "==> Backing up volumes to s3://${BUCKET}/volumes/${TIMESTAMP}/"
for VOL in "${VOLUMES[@]}"; do
  echo "  - ${VOL}"
  docker run --rm \
    -v "${PROJECT}_${VOL}:/data:ro" \
    -v "/tmp:/backup" \
    alpine tar czf "/backup/${VOL}.tar.gz" -C /data .
  aws s3 cp "/tmp/${VOL}.tar.gz" "s3://${BUCKET}/volumes/${TIMESTAMP}/${VOL}.tar.gz"
  docker run --rm -v "/tmp:/backup" alpine rm "/backup/${VOL}.tar.gz"
done

# 最新タイムスタンプを記録（restore 時のデフォルト）
echo "$TIMESTAMP" | aws s3 cp - "s3://${BUCKET}/volumes/latest.txt"

echo ""
echo "==> Backup complete: ${TIMESTAMP}"
