locals {
  otel_domain    = "${var.otel_subdomain}.${trimsuffix(data.aws_route53_zone.main.name, ".")}"
  grafana_domain = "${var.grafana_subdomain}.${trimsuffix(data.aws_route53_zone.main.name, ".")}"

  # subnet 指定時はその VPC に SG を紐づける。vpc_id も指定されていれば一致必須（precondition）
  vpc_id_for_security_group = var.subnet_id != null ? coalesce(var.vpc_id, data.aws_subnet.ec2[0].vpc_id) : var.vpc_id
}

data "aws_subnet" "ec2" {
  count = var.subnet_id != null ? 1 : 0
  id    = var.subnet_id
}

check "vpc_requires_subnet" {
  assert {
    condition     = var.vpc_id == null || var.subnet_id != null
    error_message = "vpc_id を指定する場合は subnet_id も指定してください（サブネットはその VPC 内である必要があります）。"
  }
}

resource "aws_security_group" "main" {
  name        = "${var.project}-sg"
  description = "Claude Code monitoring stack"
  vpc_id      = local.vpc_id_for_security_group

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ssh_open = true のときのみ SSH ポートを開く
  dynamic "ingress" {
    for_each = var.ssh_open ? [1] : []
    content {
      description = "SSH"
      from_port   = var.ssh_port
      to_port     = var.ssh_port
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# certbot の Route53 DNS チャレンジに必要な権限
resource "aws_iam_role_policy" "certbot_route53" {
  name = "certbot-route53"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:GetChange"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.hosted_zone_id}"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "main" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.main.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # パブリック IP を自動割り当て（起動のたびに変わる、EIP なし）
  associate_public_ip_address = true

  lifecycle {
    precondition {
      condition     = var.vpc_id == null || var.subnet_id == null || data.aws_subnet.ec2[0].vpc_id == var.vpc_id
      error_message = "vpc_id と subnet_id が同じ VPC に属していません。subnet の VPC に合わせて vpc_id を直すか、vpc_id を省略してください。"
    }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }

  user_data = <<-EOF
    #!/bin/bash
    # SSH ポートを変更
    sed -i 's/^#\?Port .*/Port ${var.ssh_port}/' /etc/ssh/sshd_config
    systemctl restart sshd

    # docker-compose ファイルを配置するディレクトリを作成
    mkdir -p /opt/claude-monitoring
    chown ec2-user:ec2-user /opt/claude-monitoring
  EOF

  tags = {
    Name = var.project
  }
}
