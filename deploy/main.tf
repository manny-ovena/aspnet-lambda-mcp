provider "aws" {
  region = "us-east-1"
}

resource "terraform_data" "build_dotnet" {
  triggers_replace = [
    timestamp() # Forces a re-build on every execution to capture code changes
  ]

  provisioner "local-exec" {
    command = "dotnet publish ${path.module}/../src/Mcp.WebApi/Mcp.WebApi.csproj -c Release -r linux-x64 --self-contained false -o ${path.module}/../src/Mcp.WebApi/publish"
  }
}

# Automatically creates the compressed zip folder from the compiled output folder
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/Mcp.WebApi/publish"
  output_path = "${path.module}/bootstrap.zip"

  depends_on = [terraform_data.build_dotnet]
}

# 1. IAM Role for Lambda Execution
resource "aws_iam_role" "lambda_role" {
  name = "aspnet_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# 2. Lambda Function
resource "aws_lambda_function" "aspnet_api" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "aspnet-lambda-mcp"
  role          = aws_iam_role.lambda_role.arn
  handler       = "Mcp.WebApi"
  runtime       = "dotnet10"
  memory_size   = 512
  timeout       = 15

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}

# 3. HTTP API Gateway
resource "aws_apigatewayv2_api" "http_api" {
  name          = "aspnet-http-api"
  protocol_type = "HTTP"
}

# 4. API Gateway Stage
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

# 5. Integration between API Gateway and Lambda
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.aspnet_api.invoke_arn
  payload_format_version = "2.0"
}

# 6. Catch-all Route to pass all traffic to ASP.NET Core routing middleware
resource "aws_apigatewayv2_route" "catch_all" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "root" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# 7. Permission for API Gateway to invoke Lambda
resource "aws_lambda_permission" "api_gw_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aspnet_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# 8. Output the entrypoint URL
output "api_url" {
  value       = aws_apigatewayv2_stage.default.invoke_url
  description = "The URL to access your ASP.NET Core API"
}