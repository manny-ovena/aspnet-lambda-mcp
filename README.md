# ASP.NET Core Lambda MCP Server

A .NET 10 [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server that exposes GitHub operations as tools. It runs locally with ASP.NET Core and uses Terraform to deploy to AWS Lambda behind API Gateway.

The MCP endpoint is `/mcp`, using the SDK's HTTP transport.

## Tools

| Tool | Arguments | Result |
| --- | --- | --- |
| `get_repositories` | `owner` (string) | Repositories returned by GitHub's repositories-for-user API, projected to name and owner. |

Use MCP's `tools/list` method to discover the tool names and input schemas exposed by the running server.

The GitHub client currently makes unauthenticated requests. Private repositories are not supported, and GitHub's unauthenticated API rate limits apply. The repository lookup uses the user endpoint, not a dedicated organization endpoint.

## OAuth access control

Terraform provisions an Amazon Cognito user pool and OAuth app client, and configures an API Gateway JWT authorizer. The MCP endpoint requires a Cognito access token with audience bound to the MCP resource URL and the `mcp/tools` scope. ASP.NET Core validates the same issuer, audience, and scope as defense in depth. Protected resource metadata is served at `/.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp`; unauthenticated requests include a `WWW-Authenticate` challenge with the metadata URL and required scope.

Cognito issues authorization-code tokens with PKCE and supports the OAuth `resource` parameter used to bind the token audience to this MCP server. Cognito does not dynamically register OAuth clients: pre-register each MCP client's callback URL in `oauth_callback_urls` and configure the client with the Terraform output `cognito_app_client_id`. The Cognito domain prefix must be globally unique in the AWS region. User self-signup is disabled by default; create users administratively, or explicitly enable it with `-var="cognito_allow_self_signup=true"`.

Terraform creates the endpoint and derives the OAuth resource URL and Cognito issuer. Set the unique domain prefix and register the callback URLs before applying:

```bash
terraform -chdir=deploy apply \
  -var='cognito_domain_prefix=your-unique-prefix' \
  -var='oauth_callback_urls=["http://localhost:3000/callback"]'
```

After applying, configure MCP clients with the Cognito app-client ID (`cognito_app_client_id`), Cognito managed-login domain (`cognito_hosted_ui_url`), OAuth authorization-code flow with PKCE, resource output (`mcp_resource_url`), and scope `mcp/tools`. Configure callback URLs for the actual MCP clients you intend to use. Do not use an ID token as the bearer token.

## Prerequisites

- .NET 10 SDK.
- Network access to the GitHub API.
- For deployment: Terraform, an AWS account, and configured AWS credentials with permission to create the configured resources.

## Run locally

From the project root:

```bash
export ASPNETCORE_ENVIRONMENT=Development
export Authentication__Authority="$(terraform -chdir=deploy output -raw cognito_issuer)"
export Authentication__Audience="https://localhost:5082/mcp"
export Authentication__Resource="$Authentication__Audience"
export Authentication__RequiredScope="mcp/tools"

dotnet restore Mcp.slnx
dotnet build Mcp.slnx --no-restore
dotnet run --project src/Mcp.WebApi --no-launch-profile -- \
  --urls https://localhost:5082
```

The local endpoint needs a trusted HTTPS development certificate (`dotnet dev-certs https --trust`). Configure the OAuth client to request `https://localhost:5082/mcp` as its resource and ensure its callback URL is registered in Cognito. Connect an MCP client that supports Streamable HTTP to:

```text
https://localhost:5082/mcp
```

## Call the server with curl

MCP is a protocol, not a conventional JSON REST API. With the current default HTTP transport configuration, initialize a session before calling tools, send the initialization notification, and reuse the returned session ID.

The following Bash example uses protocol version `2025-03-26`. If the initialization response negotiates a different version, use that value in subsequent `MCP-Protocol-Version` headers.

### 1. Initialize a session

```bash
MCP_URL="http://localhost:5082/mcp"
HEADERS_FILE="$(mktemp)"

curl -sS --no-buffer --max-time 30 -D "$HEADERS_FILE" \
  -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-03-26",
      "capabilities": {},
      "clientInfo": {"name": "curl", "version": "1.0.0"}
    }
  }'

MCP_SESSION_ID="$(sed -n 's/^[Mm][Cc][Pp]-[Ss]ession-[Ii][Dd]:[[:space:]]*//p' "$HEADERS_FILE" | tr -d '\r')"
rm "$HEADERS_FILE"

printf '\nSession ID: %s\n' "$MCP_SESSION_ID"
```

If initialization fails or no session ID is returned, inspect the HTTP response and server logs before continuing.

### 2. Complete initialization

```bash
curl -sS -i --max-time 30 -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $MCP_SESSION_ID" \
  -H 'MCP-Protocol-Version: 2025-03-26' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
```

An accepted notification can return HTTP `202` with no response body.

### 3. Discover tools

```bash
curl -sS -i --no-buffer --max-time 30 -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $MCP_SESSION_ID" \
  -H 'MCP-Protocol-Version: 2025-03-26' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### 4. List repositories

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "get_repositories",
    "arguments": {"owner": "octocat"}
  }
}
```

Responses may be delivered as server-sent events (`event:` / `data:` lines), rather than as a plain JSON response body.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| curl appears to return nothing | Use `-sS -i --no-buffer --max-time 30` to expose connection errors, HTTP status/headers, and streamed output. `-s` alone hides curl error messages. |
| MCP request is rejected | Include both accepted response types, initialize first, and reuse the session ID and negotiated protocol version. Check the HTTP response for the specific error. |
| Session is no longer recognized | Initialize a new session after restarting the server. |
| Repository lookup fails | Check the GitHub username, network connectivity, and unauthenticated rate limits. |

## Project structure

```text
Mcp.slnx
Directory.Packages.props          Central NuGet package versions
deploy/
  main.tf                         Terraform configuration for Lambda and API Gateway HTTP API
src/
  Mcp.Application/                Service interfaces and result records
  Mcp.Infrastructure/             GitHub client implementation
  Mcp.WebApi/                     ASP.NET Core entry point and MCP tools
    Tools/                        Tool definitions discovered from the assembly
tests/
  Mcp.WebApi.UnitTests/           xUnit unit tests for Web API tools
```

`Program.cs` registers the GitHub service and tool, maps `/mcp`, and enables Lambda hosting with `LambdaEventSource.HttpApi`, matching the API Gateway HTTP API and payload format configured by Terraform.

## Deploy with Terraform

The Terraform configuration in `deploy/` builds the web project locally, packages the publish output, and deploys a Lambda function behind an API Gateway HTTP API using payload format `2.0`. It requires Terraform, the .NET 10 SDK, and AWS credentials with permission to create the configured resources. The AWS region is currently set to `us-east-1` in `deploy/main.tf`.

```bash
terraform -chdir=deploy init
terraform -chdir=deploy plan
terraform -chdir=deploy apply
```

Terraform runs `dotnet publish` on the machine running Terraform and rebuilds the package on each apply. After deployment, get the API base URL with:

```bash
terraform -chdir=deploy output -raw api_url
```

Append `/mcp` to the output URL to reach the MCP endpoint. To remove the deployed resources, run `terraform -chdir=deploy destroy`.

**Transport compatibility:** the application currently uses the default stateful MCP HTTP transport. The Terraform deployment configuration alone does not establish support for persistent MCP sessions or SSE delivery across Lambda invocations. Review stateless transport, response buffering/streaming, and session handling for your deployment before relying on it.

**Access control:** the application currently configures no authentication or authorization for `/mcp`. The Terraform configuration grants the Lambda basic execution policy for logging. Restrict access and use appropriate least-privilege deployment permissions before exposing the service beyond a trusted environment.
