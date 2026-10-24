using Mcp.Application.Services;
using Octokit;

namespace Mcp.Infrastructure.GitHub;

public class GitHubService : IGitHubService
{
    private readonly IGitHubClient _gitHubClient;

    public GitHubService(IGitHubClient gitHubClient)
    {
        _gitHubClient = gitHubClient;
    }

    public async Task<IEnumerable<Application.Services.Repository>> ListRepositoriesAsync(string owner)
    {
        var repositories = await _gitHubClient.Repository.GetAllForUser(owner);
        return repositories.Select(r => new Application.Services.Repository(r.Name, r.Owner.Login));
    }
}