using Octokit;

namespace Mcp.Infrastructure.GitHub;

public static class GitHubClientFactory
{
    public static IGitHubClient Create() => 
        new GitHubClient(new ProductHeaderValue("Mcp"));
}