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

# 証明書の自動更新（systemd timer + service）
# Amazon Linux 2023 には cron が無く、pip 版 certbot は標準の certbot.timer を
# 同梱しないため、自前で timer/service を登録する。
# renew は期限 30 日前のものだけ更新するので 1 日 2 回実行で問題ない（公式推奨）。
# --deploy-hook で更新成功時のみ nginx を reload し、新しい証明書を読み直させる。
CERTBOT_BIN="$(command -v certbot)"

cat > /etc/systemd/system/certbot-renew.service <<EOF
[Unit]
Description=Certbot renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CERTBOT_BIN} renew --quiet --deploy-hook "systemctl reload nginx"
EOF

cat > /etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Run certbot renew twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now certbot-renew.timer

echo "==> Auto-renewal timer enabled (certbot-renew.timer)."
echo "==> Next steps:"
echo "    1. Deploy config files to /opt/claude-monitoring"
echo "    2. Run: .\manage.ps1 deploy -KeyFile <key>"