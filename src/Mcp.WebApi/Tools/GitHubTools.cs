using System.ComponentModel;
using Mcp.Application.Services;
using ModelContextProtocol.Server;

namespace Mcp.WebApi.Tools;

[McpServerToolType]
public class GitHubTools
{
    private readonly IGitHubService _gitHubService;

    public GitHubTools(IGitHubService gitHubService)
    {
        _gitHubService = gitHubService;
    }

    [McpServerTool]
    [Description("Get repositories for a given owner")]
    public async Task<IEnumerable<Repository>> GetRepositoriesAsync(string owner) =>
        await _gitHubService.ListRepositoriesAsync(owner);
}
