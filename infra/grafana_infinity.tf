# ─── Grafana Infinityデータソース用 IAMユーザー（コールドパス S3 読み取り専用） ──
# Infinity datasourceプラグインはIAMロール/デフォルト認証チェーンに対応せず
# アクセスキー方式のみサポートするため、EC2 IAMロール（ec2.tf の athena_iot_monitor
# ポリシー、Athenaデータソースが使っている）とは別に専用IAMユーザーを払い出す。
# rollup/ 配下は「確定済みhourパーティションの集計結果」を置く想定の新規プレフィックス
# （書き込み側のバッチ処理は car-iot-services 側で未実装、Grafana側の設定を先行させる
# ためのプレースホルダー）。

resource "aws_iam_user" "grafana_infinity" {
  name = "${var.project}-grafana-infinity"
}

resource "aws_iam_user_policy" "grafana_infinity" {
  name = "grafana-infinity-s3-read"
  user = aws_iam_user.grafana_infinity.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::iot-monitor-${data.aws_caller_identity.current.account_id}"
        Condition = {
          StringLike = {
            "s3:prefix" = "rollup/*"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::iot-monitor-${data.aws_caller_identity.current.account_id}/rollup/*"
      },
    ]
  })
}

resource "aws_iam_access_key" "grafana_infinity" {
  user = aws_iam_user.grafana_infinity.name
}
