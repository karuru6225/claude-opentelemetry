# claude-opentelemetry

Claude Code の利用状況（コスト・トークン・セッション数）を OpenTelemetry で収集し、Grafana で可視化する自前の監視スタック。

```text
Claude Code (local)
    │ OTLP over HTTPS
    ▼
otel.<domain>  ──┐
                  ├── EC2 t3.micro (動的IP + Route53 自動更新)
grafana.<domain>──┘
                      nginx (Let's Encrypt)
                      ├── OTel Collector :4318 (Basic Auth)
                      └── Grafana :3000
                              │
                          Prometheus :9090 (メトリクス)
                          Loki :3100 (ログ)
```

**収集データ**: メトリクス（コスト・トークン・セッション数）→ Prometheus、ログ（ツール呼び出し履歴）→ Loki

**コスト**: 使用時のみ起動（~$3/月）

![Grafana ダッシュボード](docs/images/grafana_dashboard.png)

---

## 前提条件

- AWS アカウント・CLI 設定済み（`aws login` で SSO 可）
- Route53 で管理しているドメイン
- Terraform >= 1.5
- EC2 キーペア作成済み

```powershell
# キーペア作成（未作成の場合）
aws ec2 create-key-pair --key-name claude-monitoring `
  --query 'KeyMaterial' --output text `
  | Out-File -Encoding ascii "$HOME\.ssh\claude-monitoring.pem"
```

---

## 初回セットアップ

### 1. S3 バックエンド用バケットを作成

```powershell
aws s3 mb s3://claude-monitoring-tfstate --region ap-northeast-1
```

### 2. 設定ファイルを用意

```powershell
cp infra\terraform.tfvars.example infra\terraform.tfvars
cp infra\backend.tfbackend.example infra\backend.tfbackend
cp .env.example .env
```

`infra\terraform.tfvars` を編集：

```hcl
hosted_zone_id = "Z0000000000000000000"  # Route53 ホストゾーン ID
ssh_key_name   = "claude-monitoring"     # EC2 キーペア名
```

`infra\backend.tfbackend` を確認（デフォルトのまま変更不要）：

```hcl
bucket = "claude-monitoring-tfstate"
key    = "terraform.tfstate"
region = "ap-northeast-1"
```

### 3. AWS リソースを作成

```powershell
cd infra
.\manage.ps1 apply -Profile default
cd ..
```

### 4. EC2 を起動して Route53 を更新

```powershell
.\manage.ps1 start -Profile default
```

### 5. EC2 初期設定（docker / nginx / certbot / TLS 証明書）

```powershell
.\manage.ps1 setup -KeyFile $HOME\.ssh\claude-monitoring.pem -Profile default
```

### 6. .env を編集

```powershell
# htpasswd ハッシュを生成（claude が OTel Collector のユーザー名）
docker run --rm httpd htpasswd -nbB claude <任意のパスワード>
```

`.env` を開いて以下を設定：

```ini
OTEL_HTPASSWD=claude:$2y$05$...  # 上で生成したハッシュ
GF_SECURITY_ADMIN_PASSWORD=...   # Grafana 管理者パスワード
```

### 7. 設定ファイルをデプロイしてコンテナ起動

```powershell
.\manage.ps1 deploy -KeyFile $HOME\.ssh\claude-monitoring.pem -Profile default
```

> **注意**: 初回デプロイ時は `grafana_data` ボリュームが存在しない状態で起動する必要がある。既存ボリュームがある場合は削除してから再デプロイ。
>
> ```bash
> docker compose down && docker volume rm claude-monitoring_grafana_data
> ```

---

## 日常の使い方

### 作業開始時

```powershell
.\manage.ps1 start -Profile default
# DNS 反映まで最大 60 秒
```

### 作業終了時

```powershell
.\manage.ps1 stop -Profile default
```

### 設定変更後の再デプロイ

```powershell
.\manage.ps1 start -Profile default
.\manage.ps1 deploy -KeyFile $HOME\.ssh\claude-monitoring.pem -Profile default
```

---

## Claude Code の設定

`~/.claude/settings.json` に追加：

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.<your-domain>",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Basic <base64(claude:<password>)>",
    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "delta",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_LOG_TOOL_DETAILS": "1"
  }
}
```

`OTEL_LOG_TOOL_DETAILS=1` を設定するとツール呼び出しの入力引数（読んだファイルパス、WebFetchのURL等）もLokiに記録される。

`Authorization` ヘッダーの値は次のコマンドで生成：

```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("claude:<password>"))
```

---

## SSH アクセス

SSH ポートはデフォルト `2222`。開閉は Terraform で管理：

```hcl
# infra/terraform.tfvars
ssh_open = true   # 開く
ssh_open = false  # 閉じる（デフォルト）
```

変更後に `infra\manage.ps1 apply` で反映。

```powershell
ssh -i $HOME\.ssh\claude-monitoring.pem -p 2222 ec2-user@<IP>
```

---

## manage.ps1 コマンド一覧

| コマンド | 説明 |
| --- | --- |
| `.\manage.ps1 start` | EC2 起動 + Route53 A レコード更新 |
| `.\manage.ps1 stop` | EC2 停止 |
| `.\manage.ps1 setup -KeyFile <pem>` | 初回のみ: docker/nginx/certbot インストール |
| `.\manage.ps1 deploy -KeyFile <pem>` | 設定ファイル転送 + nginx 設定 + コンテナ起動 |

すべてのコマンドに `-Profile <name>` を付けると AWS プロファイルを指定できる。

---

## 会社展開時の拡張

`.env` の以下を有効化するだけで Google Workspace SSO が使える：

```ini
GF_AUTH_GOOGLE_ENABLED=true
GF_AUTH_GOOGLE_CLIENT_ID=<GCP OAuth クライアント ID>
GF_AUTH_GOOGLE_CLIENT_SECRET=<シークレット>
GF_AUTH_GOOGLE_ALLOWED_DOMAINS=yourcompany.com
```

その後 `.\manage.ps1 deploy` で反映。
