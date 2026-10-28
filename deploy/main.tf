provider "aws" {
  region = "us-east-1"
}

data "aws_region" "current" {}

variable "cognito_domain_prefix" {
  description = "Globally unique Cognito managed-login domain prefix in the configured AWS region."
  type        = string
}

variable "oauth_callback_urls" {
  description = "Pre-registered OAuth callback URLs for MCP clients using the Cognito app client."
  type        = list(string)

  validation {
    condition     = length(var.oauth_callback_urls) > 0
    error_message = "At least one OAuth callback URL must be configured."
  }
}

variable "cognito_allow_self_signup" {
  description = "Whether users can create Cognito accounts without an administrator."
  type        = bool
  default     = false
}

locals {
  oauth_scope     = "mcp/tools"
  oauth_authority = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.mcp.id}"
  oauth_resource  = "https://${aws_apigatewayv2_api.http_api.id}.execute-api.${data.aws_region.current.region}.amazonaws.com/mcp"
}

resource "aws_cognito_user_pool" "mcp" {
  name                     = "aspnet-lambda-mcp"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = !var.cognito_allow_self_signup
  }
}

resource "aws_cognito_user_pool_domain" "mcp" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.mcp.id
}

resource "aws_cognito_resource_server" "mcp" {
  identifier   = "mcp"
  name         = "MCP server"
  user_pool_id = aws_cognito_user_pool.mcp.id

  scope {
    scope_name        = "tools"
    scope_description = "Access MCP tools"
  }
}

resource "aws_cognito_user_pool_client" "mcp" {
  name                                 = "mcp-client"
  user_pool_id                         = aws_cognito_user_pool.mcp.id
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", local.oauth_scope]
  callback_urls                        = var.oauth_callback_urls
  supported_identity_providers         = ["COGNITO"]
  enable_token_revocation              = true
  prevent_user_existence_errors        = "ENABLED"

  depends_on = [aws_cognito_resource_server.mcp]
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.http_api.id
  name             = "cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [local.oauth_resource]
    issuer   = local.oauth_authority
  }
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

  environment {
    variables = {
      Authentication__Authority     = local.oauth_authority
      Authentication__Audience      = local.oauth_resource
      Authentication__Resource      = local.oauth_resource
      Authentication__RequiredScope = local.oauth_scope
    }
  }

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
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "ANY /{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
  authorization_scopes = [
    local.oauth_scope
  ]
}

resource "aws_apigatewayv2_route" "root" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "ANY /"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
  authorization_scopes = [
    local.oauth_scope
  ]
}

resource "aws_apigatewayv2_route" "oauth_resource_metadata" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "GET /.well-known/oauth-protected-resource"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "NONE"
}

resource "aws_apigatewayv2_route" "oauth_mcp_resource_metadata" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "GET /.well-known/oauth-protected-resource/mcp"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "NONE"
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

output "mcp_resource_url" {
  value       = local.oauth_resource
  description = "The OAuth resource/audience URL for this MCP server."
}

output "cognito_issuer" {
  value       = local.oauth_authority
  description = "The Cognito OIDC issuer URL."
}

output "cognito_hosted_ui_url" {
  value       = "https://${aws_cognito_user_pool_domain.mcp.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
  description = "The Cognito managed-login domain for OAuth authorization."
}

output "cognito_app_client_id" {
  value       = aws_cognito_user_pool_client.mcp.id
  description = "The public OAuth app client ID to configure in MCP clients."
}