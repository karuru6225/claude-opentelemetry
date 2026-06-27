# Claude Code 監視スタック 引き継ぎ資料

## 現在の状態

構築・稼働済み。AWS EC2 上で動作している。

---

## アーキテクチャ

```text
Claude Code (local)
    │ OTLP HTTP/protobuf (Basic 認証)
    ▼
nginx (Let's Encrypt TLS)
    ├── otel.<domain>:443  → OTel Collector :4318
    └── grafana.<domain>:443 → Grafana :3000

EC2 t3.micro (動的IP + Route53 自動更新、EIP なし)
    └── docker compose
          ├── otel-collector (otel/opentelemetry-collector-contrib)
          │     ├── metrics → prometheusremotewrite → Prometheus :9090
          │     └── logs    → otlp_http/loki        → Loki :3100
          ├── prometheus
          ├── loki
          └── grafana (user: 1000:1000)
```

---

## Claude Code 側の設定

`~/.claude/settings.json` の `env` セクション：

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

### 各設定の意図

- `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: delta` — プロセス再起動によるカウンターリセットでグラフが落ちないようにするため delta を使用。Collector 側で累積に変換して Prometheus に送る
- `OTEL_LOG_TOOL_DETAILS: 1` — ツール呼び出しの入力引数（ファイルパス、WebFetch URL等）を Loki に記録する
- `OTEL_LOGS_EXPORTER` は公式ドキュメントに記載あり（動作確認済み）
- `OTEL_TRACES_EXPORTER` は未実装のため設定不要

---

## 取得できるデータ

### メトリクス（Prometheus）

| メトリック名 | 内容 |
| --- | --- |
| `claude_code_cost_usage_USD_total` | コスト（USD） |
| `claude_code_token_usage_tokens_total` | トークン消費量（type: input/output/cache_read/cache_creation） |
| `claude_code_session_count_total` | セッション数 |
| `claude_code_lines_of_code_count_total` | 変更コード行数 |
| `claude_code_code_edit_tool_decision_total` | コード編集ツール決定数 |

ラベル: `model`, `session_id`, `user_email`, `organization_id` など

### ログイベント（Loki）

| イベント名 | 内容 |
| --- | --- |
| `claude_code.api_request` | API リクエスト（コスト・トークン情報含む） |
| `claude_code.user_prompt` | ユーザー入力 |
| `claude_code.tool_decision` | ツール呼び出し判断 |
| `claude_code.tool_result` | ツール実行結果（tool_name、duration_ms 等） |
| `claude_code.api_error` | API エラー |

---

## Grafana

### データソース

- Prometheus: `uid: prometheus`、`http://prometheus:9090`
- Loki: `uid: loki`、`http://loki:3100`

いずれも provisioning で自動設定済み（`grafana/provisioning/datasources/`）。

### プロビジョニングダッシュボード

`grafana/provisioning/dashboards/claude-code.json` が自動ロードされる。

delta temporality に対応するため、stat パネルのクエリは `increase(metric[$__range])` 形式を使用。

### Loki の有用なクエリ

```logql
# ツール別の呼び出し回数
sum by (tool_name) (
  count_over_time({service_name="claude-code"} | tool_name != "" [1h])
)

# WebFetch のログ詳細
{service_name="claude-code"} | tool_name="WebFetch"
```

---

## 既知のハマりポイント

### OTel Collector の exporter 名

`loki` exporter はこのバージョン（v0.148.0）に含まれていない。Loki の OTLP エンドポイント（`:3100/otlp`）に `otlp_http/loki` で送る。`otlphttp` は非推奨（`otlp_http` を使う）。

### Grafana の権限問題

Grafana コンテナは `user: "1000:1000"` で起動（ec2-user と同じ UID）。これにより provisioning ファイルの読み取り権限が解決される。

`grafana_data` ボリュームが uid 472（旧 Grafana デフォルト）で作られている場合は起動失敗する。その場合はボリュームを削除して再作成：

```bash
docker compose down
docker volume rm claude-monitoring_grafana_data
docker compose up -d
```

### Grafana provisioning の古いファイル残留

deploy 時に `grafana/` ディレクトリをリモートで一度削除してから転送する（manage.ps1 内で処理済み）。削除しないと削除済みの datasource ファイルが残り、存在しないサービスを参照して Grafana が起動失敗する。

### Prometheus 503 エラー

Collector 再起動直後に Prometheus への remote write が 503 になることがある。retry で自動回復するため放置でよい。

### 証明書失効で Grafana がアプリファイルを読めない（ERR_CERT_DATE_INVALID）

**症状**: Grafana が `ChunkLoadError` → "Grafana has failed to load its application files" を表示。DevTools の Network で CSS/JS が軒並み `net::ERR_CERT_DATE_INVALID` で失敗している。

**原因**: Let's Encrypt 証明書の失効。nginx が期限切れの証明書を握っているため、HTML（キャッシュから表示される）は出るが後続アセットの取得が全て TLS で弾かれる。Grafana 本体やビルド成果物は無関係。

**確認**:

```bash
echo | openssl s_client -connect grafana.<domain>:443 -servername grafana.<domain> 2>/dev/null \
  | openssl x509 -noout -dates   # notAfter が過去なら失効
```

**復旧**:

```bash
certbot renew            # 期限切れなら更新（dns-route53 認証は自動）
systemctl reload nginx   # 新しい証明書を読み直させる
```

→ ブラウザをスーパーリロード（Ctrl/Cmd+Shift+R）で復活。詳細は「インフラ管理 → TLS 証明書」を参照。

---

## インフラ管理

### EC2

- リージョン: ap-northeast-1
- インスタンスタイプ: t3.micro
- EIP なし（起動のたびに IP が変わる）
- 起動時に manage.ps1 start で Route53 A レコードを更新

### SSH

- ポート: 2222
- キーペア: `claude-monitoring`
- Terraform の `ssh_open` 変数で Security Group を開閉

### TLS 証明書

- 取得・更新とも Let's Encrypt + certbot（`--dns-route53` DNS チャレンジ）。EC2 の IAM ロールで Route53 を操作するため、IP が起動のたびに変わっても更新可能（HTTP-01 と違いポート 80 開放不要）。
- `setup.sh` が初回に証明書取得と**自動更新タイマーの登録**まで行う。Amazon Linux 2023 は cron 非搭載・pip 版 certbot は標準 timer を同梱しないため、`certbot-renew.{service,timer}` を自前で登録している（1 日 2 回チェック、期限 30 日前のものだけ更新）。更新成功時は `--deploy-hook` で nginx を reload。

確認・運用コマンド：

```bash
systemctl list-timers | grep certbot          # 次回実行予定の確認
journalctl -u certbot-renew --no-pager | tail  # 更新ログ
certbot certificates                           # 各証明書の有効期限一覧
certbot renew --dry-run                         # 更新経路の疎通テスト（発行はしない）
```

> 自動更新が登録されていないと 90 日で失効し、Grafana/otel が ERR_CERT_DATE_INVALID で全滅する（「既知のハマりポイント」参照）。`list-timers` に `certbot-renew.timer` が出ていることを時々確認しておくと安心。

### Terraform

- バックエンド: S3 (`claude-monitoring-tfstate`)
- 管理コマンド: `infra\tf.ps1 apply/plan/destroy`

### コスト

- EC2 停止中: ほぼ $0
- 稼働中: ~$3/月（t3.micro オンデマンド）

---

## manage.ps1 コマンド

| コマンド | 説明 |
| --- | --- |
| `.\manage.ps1 start` | EC2 起動 + Route53 更新 |
| `.\manage.ps1 stop` | EC2 停止 |
| `.\manage.ps1 setup -KeyFile <pem>` | 初回のみ: docker/nginx/certbot インストール |
| `.\manage.ps1 deploy -KeyFile <pem>` | 設定ファイル転送 + コンテナ再起動 |

---

## 会社展開時の拡張

`.env` で Google Workspace OAuth を有効化するだけで SSO が使える：

```ini
GF_AUTH_GOOGLE_ENABLED=true
GF_AUTH_GOOGLE_CLIENT_ID=<クライアント ID>
GF_AUTH_GOOGLE_CLIENT_SECRET=<シークレット>
GF_AUTH_GOOGLE_ALLOWED_DOMAINS=yourcompany.com
```
