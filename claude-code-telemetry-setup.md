# Claude Code テレメトリ設定ガイド

このドキュメントを読んで、指示に従って設定を完了してください。

---

## やること

`~/.claude/settings.json` に OTel の設定を追加する。
ファイルが存在しない場合は新規作成する。

---

## 設定値の確認

作業を始める前に、以下の2つを別途確認してください：

- **OTLP エンドポイント**: `https://otel.example.com` のような URL
- **パスワード**: Basic 認証のパスワード文字列

---

## 手順

### 1. Authorization ヘッダー値を生成

以下のコマンドでパスワードから Base64 エンコードされたヘッダー値を生成します。
`<パスワード>` の部分を実際のパスワードに置き換えて実行してください：

**Mac / Linux (bash):**
```bash
echo -n "claude:<パスワード>" | base64
```

**Windows (PowerShell):**
```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("claude:<パスワード>"))
```

出力された文字列（例: `Y2xhdWRlOnBhc3N3b3Jk`）をメモしておきます。

### 2. settings.json を編集

`~/.claude/settings.json` を開き、`env` セクションに以下を追加します。
既存の `env` セクションがある場合はマージしてください。

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "<エンドポイントURLをここに>",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Basic <手順1で生成した文字列>",
    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "delta",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_LOG_TOOL_DETAILS": "1"
  }
}
```

**設定例（値を埋めた状態）:**

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.example.com",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Basic Y2xhdWRlOnBhc3N3b3Jk",
    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "delta",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_LOG_TOOL_DETAILS": "1"
  }
}
```

### 3. Claude Code を再起動

設定を反映するため、Claude Code を一度終了して再起動します。

---

## 設定の意味

| キー | 値 | 意味 |
|---|---|---|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1` | テレメトリを有効化 |
| `OTEL_METRICS_EXPORTER` | `otlp` | メトリクスを OTLP で送信 |
| `OTEL_LOGS_EXPORTER` | `otlp` | ログを OTLP で送信 |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | HTTP/protobuf 形式で送信 |
| `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` | `delta` | メトリクスを差分形式で送信（再起動時のグラフ断絶を防ぐ） |
| `OTEL_METRIC_EXPORT_INTERVAL` | `10000` | メトリクス送信間隔（10秒） |
| `OTEL_LOGS_EXPORT_INTERVAL` | `5000` | ログ送信間隔（5秒） |
| `OTEL_LOG_TOOL_DETAILS` | `1` | ツール呼び出しの詳細（ファイルパス、URL等）もログに記録 |

---

## 送信されるデータ

**メトリクス（Grafana で可視化）:**
- コスト（USD）
- トークン消費量（input / output / cache_read / cache_creation 別）
- セッション数
- コード変更行数

**ログ（Loki で検索可能）:**
- API リクエスト（コスト・トークン情報含む）
- ユーザー入力
- ツール呼び出し（ファイル読み書き、WebFetch 等）とその結果

`OTEL_LOG_TOOL_DETAILS=1` を設定した場合、読んだファイルのパスや WebFetch した URL も記録されます。
記録したくない場合はこの行を削除してください。

---

## 完了確認

設定後、Claude Code で何かタスクを実行すると、数十秒以内に Grafana のダッシュボードにデータが反映されます。
