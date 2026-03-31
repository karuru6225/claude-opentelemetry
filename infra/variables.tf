variable "aws_region" {
  description = "AWSリージョン"
  default     = "ap-northeast-1"
}

variable "project" {
  description = "プロジェクト名（リソース名のプレフィックス・タグ）"
  default     = "claude-monitoring"
}

variable "hosted_zone_id" {
  description = "Route53 ホストゾーン ID（既存ドメインのもの）"
  type        = string
}

variable "otel_subdomain" {
  description = "OTel Collector のサブドメイン（例: otel → otel.example.com）"
  type        = string
  default     = "otel"
}

variable "grafana_subdomain" {
  description = "Grafana のサブドメイン（例: grafana → grafana.example.com）"
  type        = string
  default     = "grafana"
}

variable "ssh_open" {
  description = "SSH ポートを Security Group で開くか（true: 開く / false: 閉じる）"
  type        = bool
  default     = false
}

variable "ssh_port" {
  description = "SSH ポート番号（デフォルト: 2222）"
  type        = number
  default     = 2222
}

variable "ssh_key_name" {
  description = "EC2 に使用する SSH キーペア名"
  type        = string
}

variable "instance_type" {
  description = "EC2 インスタンスタイプ"
  default     = "t3.micro"
}

variable "vpc_id" {
  description = "既存 VPC ID。省略時はリージョンのデフォルト VPC 上に Security Group / EC2 を配置。subnet_id を指定する場合、省略するとサブネットから VPC を自動判定"
  type        = string
  default     = null
  nullable    = true
}

variable "subnet_id" {
  description = "EC2 を配置するサブネット ID（パブリック IP が必要ならパブリックサブネットを指定）。省略時はデフォルト VPC の既定の挙動"
  type        = string
  default     = null
  nullable    = true
}
