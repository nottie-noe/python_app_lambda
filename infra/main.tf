terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# S3 Bucket for File Uploads
resource "aws_s3_bucket" "file_bucket" {
  bucket = "lambda-file-processor-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "encrypt" {
  bucket = aws_s3_bucket.file_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

# Lambda Function
resource "aws_lambda_function" "file_processor" {
  filename      = "lambda.zip"
  function_name = "s3-file-processor"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"

  environment {
    variables = {
      S3_BUCKET      = aws_s3_bucket.file_bucket.id
      SNS_TOPIC_ARN = os.getenv('SNS_TOPIC_ARN') # Correct reference
    }
  }

  tracing_config {
    mode = "Active"
  }
}

# S3 -> Lambda Trigger
resource "aws_s3_bucket_notification" "lambda_trigger" {
  bucket = aws_s3_bucket.file_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.file_processor.arn
    events              = ["s3:ObjectCreated:*"]
  }
}

# API Gateway
resource "aws_api_gateway_rest_api" "file_api" {
  name = "file-processor-api"
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.file_api.id
  parent_id   = aws_api_gateway_rest_api.file_api.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.file_api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.file_api.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.file_processor.invoke_arn
}

resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda
  ]

  rest_api_id = aws_api_gateway_rest_api.file_api.id
  stage_name  = "prod"
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec" {
  name = "lambda-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject"
      ]
      Resource = "${aws_s3_bucket.file_bucket.arn}/*"
    }]
  })
}

# API Gateway Permissions
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.file_processor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.file_api.execution_arn}/*/*"
}

output "api_url" {
  value = "${aws_api_gateway_deployment.deployment.invoke_url}/prod"
}

resource "aws_s3_bucket_lifecycle_configuration" "auto_cleanup" {
  bucket = aws_s3_bucket.file_bucket.id

  rule {
    id     = "delete-old-files"
    status = "Enabled"
    expiration {
      days = 30
    }
  }
}

  rule {
    status = "Enabled"
    destination {
      bucket = aws_s3_bucket.eu_backup.arn
    }
  }
}

# Add CloudWatch permissions
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "cloudwatch_logs"
  role = aws_iam_role.lambda_exec.parent_id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      Resource = "*"
    }]
  })
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "LambdaProcessor-Dashboard"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${aws_lambda_function.file_processor.function_name}"]
          ]
          period = 300
          stat   = "Sum"
        }
      }
    ]
  })
}

resource "aws_sns_topic" "uploads_notifications" {
  name = "s3-file-upload-notifications"
}

resource "aws_s3_bucket_notification" "lambda_trigger" {
  bucket = aws_s3_bucket.file_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.file_processor.arn
    events              = ["s3:ObjectCreated:*"]
  }

  # Add SNS notification
  topic {
    topic_arn = aws_sns_topic.uploads.arn
    events    = ["s3:ObjectCreated:*"]
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.uploads_notifications.arn
  protocol  = "email"
  endpoint  = "thandonoe.ndlovu@gmail.com"  # Replace with your email
}