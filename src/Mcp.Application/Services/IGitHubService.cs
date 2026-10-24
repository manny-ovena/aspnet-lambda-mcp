namespace Mcp.Application.Services;

public record Repository(string Name, string Owner);

public interface IGitHubService
{
    Task<IEnumerable<Repository>> ListRepositoriesAsync(string owner);
}
