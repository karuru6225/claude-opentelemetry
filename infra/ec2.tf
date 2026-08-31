locals {
  otel_domain    = "${var.otel_subdomain}.${trimsuffix(data.aws_route53_zone.main.name, ".")}"
  grafana_domain = "${var.grafana_subdomain}.${trimsuffix(data.aws_route53_zone.main.name, ".")}"

  # subnet 指定時はその VPC に SG を紐づける。vpc_id も指定されていれば一致必須（precondition）
  vpc_id_for_security_group = var.subnet_id != null ? coalesce(var.vpc_id, data.aws_subnet.ec2[0].vpc_id) : var.vpc_id

  # データ用EBSボリューム（ec2_data_volume.tf）をインスタンスと同じAZに固定するために使う。
  # subnet_id 指定時はそのサブネットのAZ、未指定時（デフォルトVPC）は利用可能なAZの先頭を使う。
  instance_az = var.subnet_id != null ? data.aws_subnet.ec2[0].availability_zone : data.aws_availability_zones.available.names[0]
}

data "aws_subnet" "ec2" {
  count = var.subnet_id != null ? 1 : 0
  id    = var.subnet_id
}

data "aws_availability_zones" "available" {
  state = "available"
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

resource "aws_iam_role_policy" "athena_iot_monitor" {
  name = "athena-iot-monitor"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
          "athena:ListWorkGroups",
        ]
        Resource = [
          "arn:aws:athena:ap-northeast-1:${data.aws_caller_identity.current.account_id}:workgroup/iot-monitor"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = [
          "arn:aws:glue:ap-northeast-1:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:ap-northeast-1:${data.aws_caller_identity.current.account_id}:database/iot_monitor",
          "arn:aws:glue:ap-northeast-1:${data.aws_caller_identity.current.account_id}:table/iot_monitor/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:PutObject",
          "s3:GetBucketLocation",
        ]
        Resource = [
          "arn:aws:s3:::iot-monitor-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::iot-monitor-${data.aws_caller_identity.current.account_id}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "main" {
  ami                    = coalesce(var.ami_id, data.aws_ami.al2023.id)
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
    volume_size = 30
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

resource "aws_eip" "main" {
  domain   = "vpc"
  instance = aws_instance.main.id

  tags = {
    Name = var.project
  }
}

# ─── リストアテスト用インスタンス ────────────────────────────────────────────
# 使い終わったら terraform.tfvars で enable_restore_test = false にして apply

resource "aws_instance" "restore_test" {
  count                  = var.enable_restore_test ? 1 : 0
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.main.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }

  user_data = <<-EOF
    #!/bin/bash
    sed -i 's/^#\?Port .*/Port ${var.ssh_port}/' /etc/ssh/sshd_config
    systemctl restart sshd
    mkdir -p /opt/claude-monitoring
    chown ec2-user:ec2-user /opt/claude-monitoring
  EOF

  tags = {
    Name = "${var.project}-restore-test"
  }
}
