using Amazon.Lambda.AspNetCoreServer;
using Mcp.Application.Services;
using Mcp.Infrastructure.GitHub;
using Mcp.WebApi.Tools;
using Microsoft.Extensions.DependencyInjection;
using ModelContextProtocol.Server;

var builder = WebApplication.CreateBuilder(args);

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

//app.UseHttpsRedirection();
//app.UseAuthorization();

app.Run();
