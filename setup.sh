#!/bin/bash
# EC2 初回セットアップスクリプト
# 使い方: sudo bash setup.sh <otel_domain> <grafana_domain> <email>
# 例:     sudo bash setup.sh otel.example.com grafana.example.com admin@example.com
set -eux

OTEL_DOMAIN="$1"
GRAFANA_DOMAIN="$2"
EMAIL="$3"

# docker インストール
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# docker compose plugin インストール
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# nginx インストール
dnf install -y nginx
systemctl enable nginx
systemctl start nginx

# certbot インストール（Route53 DNS チャレンジ用）
dnf install -y python3-pip
pip3 install certbot certbot-dns-route53

# TLS 証明書取得（ドメインごとに個別取得 → nginx.conf のパスと一致させる）
certbot certonly \
  --dns-route53 \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$OTEL_DOMAIN"

certbot certonly \
  --dns-route53 \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$GRAFANA_DOMAIN"

echo "==> Certificates issued."
echo "==> Next steps:"
echo "    1. Deploy config files to /opt/claude-monitoring"
echo "    2. Run: .\manage.ps1 deploy -KeyFile <key>"
