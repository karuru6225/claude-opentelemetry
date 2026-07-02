resource "aws_iam_role" "scheduler" {
  count = var.enable_instance_schedule ? 1 : 0
  name  = "${var.project}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_ec2" {
  count = var.enable_instance_schedule ? 1 : 0
  name  = "ec2-start-stop"
  role  = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StartInstances", "ec2:StopInstances"]
      Resource = aws_instance.main.arn
    }]
  })
}

resource "aws_scheduler_schedule" "stop" {
  count = var.enable_instance_schedule ? 1 : 0
  name  = "${var.project}-stop"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.instance_stop_cron
  schedule_expression_timezone = "Asia/Tokyo"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      InstanceIds = [aws_instance.main.id]
    })
  }
}

resource "aws_scheduler_schedule" "start" {
  count = var.enable_instance_schedule ? 1 : 0
  name  = "${var.project}-start"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.instance_start_cron
  schedule_expression_timezone = "Asia/Tokyo"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      InstanceIds = [aws_instance.main.id]
    })
  }
}
