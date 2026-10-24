using Mcp.Application.Services;
using Mcp.WebApi.Tools;
using Moq;
using Xunit;

namespace Mcp.WebApi.UnitTests;

public class GitHubToolsTests
{
    [Fact]
    public async Task GetRepositoriesAsync_PassesOwnerToServiceAndReturnsRepositories()
    {
        var repositories = new[]
        {
            new Repository("example", "octocat")
        };
        var service = new Mock<IGitHubService>();
        service
            .Setup(x => x.ListRepositoriesAsync("octocat"))
            .ReturnsAsync(repositories);
        var tools = new GitHubTools(service.Object);

        var result = await tools.GetRepositoriesAsync("octocat");

        Assert.Equal(repositories, result);
        service.Verify(x => x.ListRepositoriesAsync("octocat"), Times.Once);
    }
}
