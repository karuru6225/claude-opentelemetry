resource "aws_route53_record" "otel" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.otel_domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.main.public_ip]
}

resource "aws_route53_record" "grafana" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.grafana_domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.main.public_ip]
}
