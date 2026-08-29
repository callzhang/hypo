using Hypo.Core.Relay;

namespace Hypo.Core.Tests;

public class RelayOptionsTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-relay-opts").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private static RelayOptions Resolve(string? envValue, string searchFrom) =>
        RelayOptions.FromEnvironment(
            "11111111-2222-3333-4444-555555555555",
            "windows",
            env: name => name == RelayOptions.SecretVariable ? envValue : null,
            searchFrom: searchFrom);

    [Fact]
    public void PrefersTheEnvironmentVariable()
    {
        File.WriteAllText(Path.Combine(_dir, ".env"), $"{RelayOptions.DotEnvKey}=from-dotenv\n");

        Assert.Equal("from-env-var", Resolve("from-env-var", _dir).Secret);
    }

    [Fact]
    public void FallsBackToADotEnvFurtherUpTheTree()
    {
        File.WriteAllText(Path.Combine(_dir, ".env"), $"{RelayOptions.DotEnvKey}=from-dotenv\n");
        var nested = Directory.CreateDirectory(Path.Combine(_dir, "windows", "bin", "Debug")).FullName;

        // The tests, the harness and a git worktree all sit at different depths,
        // so the walk must not assume one.
        Assert.Equal("from-dotenv", Resolve(null, nested).Secret);
    }

    [Fact]
    public void IgnoresCommentsAndStripsQuotes()
    {
        File.WriteAllText(
            Path.Combine(_dir, ".env"),
            $"# {RelayOptions.DotEnvKey}=commented-out\nOTHER=x\n{RelayOptions.DotEnvKey}=\"quoted\"\n");

        Assert.Equal("quoted", Resolve(null, _dir).Secret);
    }

    [Fact]
    public void DoesNotMatchAKeyThatMerelyEndsWithOurs()
    {
        File.WriteAllText(
            Path.Combine(_dir, ".env"),
            $"OLD_{RelayOptions.DotEnvKey}=wrong\n{RelayOptions.DotEnvKey}=right\n");

        Assert.Equal("right", Resolve(null, _dir).Secret);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void TreatsAnAbsentOrBlankSecretAsAnError(string? value)
    {
        // No .env anywhere up the tree from an empty temp dir, so the only
        // source is the variable. A blank one counts as absent: the relay
        // rejects an empty secret, so accepting it would turn a clear error
        // here into an opaque 401 later.
        var error = Assert.Throws<InvalidOperationException>(() => Resolve(value, _dir));

        Assert.Contains(RelayOptions.SecretVariable, error.Message);
    }

    [Fact]
    public void ComputesTheAuthTokenForTheConfiguredDevice()
    {
        File.WriteAllText(Path.Combine(_dir, ".env"), $"{RelayOptions.DotEnvKey}=hypo-test-secret\n");

        var options = Resolve(null, _dir);

        Assert.Equal(RelayAuthToken.Compute("hypo-test-secret", options.DeviceId), options.AuthToken);
    }

    [Fact]
    public void DefaultsToTheDeployedRelay()
    {
        File.WriteAllText(Path.Combine(_dir, ".env"), $"{RelayOptions.DotEnvKey}=s\n");

        Assert.Equal("wss://hypo.fly.dev/ws", Resolve(null, _dir).Endpoint.ToString());
    }
}
