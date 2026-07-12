# M5AtomS3 等から EC2 を start/stop するための API Gateway + Lambda。
# 認証は共有シークレットのヘッダー比較を Lambda 内で行う
# （API Gateway HTTP API v2 はネイティブの API キー機能を持たないため）。

check "ec2_control_requires_secret" {
  assert {
    condition     = !var.enable_ec2_control || (var.ec2_control_shared_secret != null && length(var.ec2_control_shared_secret) >= 16)
    error_message = "enable_ec2_control = true のときは ec2_control_shared_secret に16文字以上の値を設定してください。"
  }
}

data "archive_file" "ec2_control" {
  count       = var.enable_ec2_control ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda_src/ec2_control/index.py"
  output_path = "${path.module}/.build/ec2_control.zip"
}

resource "aws_iam_role" "lambda_ec2_control" {
  count = var.enable_ec2_control ? 1 : 0
  name  = "${var.project}-ec2-control"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_ec2_control" {
  count = var.enable_ec2_control ? 1 : 0
  name  = "ec2-start-stop"
  role  = aws_iam_role.lambda_ec2_control[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = aws_instance.main.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "ec2_control" {
  count            = var.enable_ec2_control ? 1 : 0
  function_name    = "${var.project}-ec2-control"
  role             = aws_iam_role.lambda_ec2_control[0].arn
  filename         = data.archive_file.ec2_control[0].output_path
  source_code_hash = data.archive_file.ec2_control[0].output_base64sha256
  runtime          = "python3.12"
  handler          = "index.handler"
  timeout          = 10

  environment {
    variables = {
      INSTANCE_ID   = aws_instance.main.id
      SHARED_SECRET = var.ec2_control_shared_secret
    }
  }
}

resource "aws_apigatewayv2_api" "ec2_control" {
  count         = var.enable_ec2_control ? 1 : 0
  name          = "${var.project}-ec2-control"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "ec2_control" {
  count       = var.enable_ec2_control ? 1 : 0
  api_id      = aws_apigatewayv2_api.ec2_control[0].id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 5
    throttling_rate_limit  = 2
  }
}

resource "aws_apigatewayv2_integration" "ec2_control" {
  count                  = var.enable_ec2_control ? 1 : 0
  api_id                 = aws_apigatewayv2_api.ec2_control[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ec2_control[0].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ec2_start" {
  count     = var.enable_ec2_control ? 1 : 0
  api_id    = aws_apigatewayv2_api.ec2_control[0].id
  route_key = "POST /ec2/start"
  target    = "integrations/${aws_apigatewayv2_integration.ec2_control[0].id}"
}

resource "aws_apigatewayv2_route" "ec2_stop" {
  count     = var.enable_ec2_control ? 1 : 0
  api_id    = aws_apigatewayv2_api.ec2_control[0].id
  route_key = "POST /ec2/stop"
  target    = "integrations/${aws_apigatewayv2_integration.ec2_control[0].id}"
}

resource "aws_lambda_permission" "apigw_ec2_control" {
  count         = var.enable_ec2_control ? 1 : 0
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ec2_control[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ec2_control[0].execution_arn}/*/*"
}
