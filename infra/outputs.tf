output "instance_id" {
  description = "EC2 インスタンス ID（manage.ps1 start/stop で使用）"
  value       = aws_instance.main.id
}

output "hosted_zone_id" {
  description = "Route53 ホストゾーン ID"
  value       = data.aws_route53_zone.main.zone_id
}

output "public_ip" {
  description = "EC2 インスタンスのパブリック IP（EIP で固定）"
  value       = aws_eip.main.public_ip
}

output "domain" {
  description = "ベースドメイン名（末尾のドットなし）"
  value       = trimsuffix(data.aws_route53_zone.main.name, ".")
}

output "otel_endpoint" {
  description = "OTel Collector エンドポイント（Claude Code の OTEL_EXPORTER_OTLP_ENDPOINT に設定する）"
  value       = "https://${var.otel_subdomain}.${trimsuffix(data.aws_route53_zone.main.name, ".")}"
}

output "grafana_url" {
  description = "Grafana ダッシュボード URL"
  value       = "https://${var.grafana_subdomain}.${trimsuffix(data.aws_route53_zone.main.name, ".")}"
}

output "ssh_port" {
  description = "SSH ポート番号（manage.ps1 setup で使用）"
  value       = var.ssh_port
}

output "vpc_id" {
  description = "Security Group / EC2 が配置されている VPC ID"
  value       = aws_security_group.main.vpc_id
}

output "subnet_id" {
  description = "EC2 が配置されているサブネット ID"
  value       = aws_instance.main.subnet_id
}

output "backup_bucket" {
  description = "Docker ボリュームバックアップ用 S3 バケット名"
  value       = aws_s3_bucket.backup.bucket
}

output "restore_test_ip" {
  description = "リストアテスト用 EC2 インスタンスのパブリック IP"
  value       = var.enable_restore_test ? aws_instance.restore_test[0].public_ip : null
}

output "ec2_control_api_endpoint" {
  description = "EC2 start/stop API のベースURL（M5AtomS3の config.h に設定する）"
  value       = var.enable_ec2_control ? aws_apigatewayv2_api.ec2_control[0].api_endpoint : null
}

output "grafana_infinity_access_key_id" {
  description = "Grafana Infinityデータソース用IAMアクセスキーID。.env の INFINITY_AWS_ACCESS_KEY_ID に手動で貼る"
  value       = aws_iam_access_key.grafana_infinity.id
  sensitive   = true
}

output "grafana_infinity_secret_access_key" {
  description = "Grafana Infinityデータソース用IAMシークレットキー。.env の INFINITY_AWS_SECRET_ACCESS_KEY に手動で貼る"
  value       = aws_iam_access_key.grafana_infinity.secret
  sensitive   = true
}
