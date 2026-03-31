output "instance_id" {
  description = "EC2 インスタンス ID（manage.ps1 start/stop で使用）"
  value       = aws_instance.main.id
}

output "hosted_zone_id" {
  description = "Route53 ホストゾーン ID（manage.ps1 start で Route53 更新に使用）"
  value       = data.aws_route53_zone.main.zone_id
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
