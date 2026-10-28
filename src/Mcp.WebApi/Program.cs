using Amazon.Lambda.AspNetCoreServer;
using Mcp.Application.Services;
using Mcp.Infrastructure.GitHub;
using Mcp.WebApi.Tools;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.Tokens;
using ModelContextProtocol.Server;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddAuthentication(options =>
{
   options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
   options.DefaultChallengeScheme = JwtBearerDefaults.AuthenticationScheme;
})
.AddJwtBearer(options =>
{
    var congitoConfig = builder.Configuration.GetSection("Athentication:Cognito");
    
    if (congitoConfig == null)
        throw new InvalidOperationException("Cognito configuration is missing.");
    
    options.Authority = congitoConfig["Authority"];
    options.MetadataAddress = congitoConfig["MetadataAddress"]!;
    options.Audience = congitoConfig["Audience"];

    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer = true,
        ValidateAudience = true,
        ValidateLifetime = true,
        ValidateIssuerSigningKey = true
    };
});

builder.Services.AddAuthorization();

// Add AWS Lambda support. When application is run in Lambda Kestrel is swapped out as the web server with Amazon.Lambda.AspNetCoreServer. This
// package will act as the webserver translating request and responses between the Lambda event source and ASP.NET Core.
builder.Services.AddAWSLambdaHosting(LambdaEventSource.HttpApi);

var gitHubClient = GitHubClientFactory.Create();
builder.Services.AddSingleton<IGitHubService>(new GitHubService(gitHubClient));

builder.Services
    .AddMcpServer()
    .WithHttpTransport()
    .WithTools<GitHubTools>();

var app = builder.Build();

app.MapMcp("/mcp");

app.UseAuthentication();
app.UseAuthorization();

app.Run();
