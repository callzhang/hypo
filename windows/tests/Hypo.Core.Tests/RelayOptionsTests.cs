using Hypo.Core.Relay;

namespace Hypo.Core.Tests;

public class RelayOptionsTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-relay-opts").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    /// <summary>
    /// Writes a <c>.env</c> and the <c>.git</c> that makes it a checkout's.
    ///
    /// <para>Both, because only a checkout's <c>.env</c> counts. A bare
    /// directory with a <c>.env</c> in it is not a checkout, and the walk
    /// ignoring it is the point -- otherwise any file anywhere above the
    /// application that happens to define the key would be used.</para>
    /// </summary>
    private string Checkout(string dotEnv, string? at = null)
    {
        var root = at ?? _dir;

        Directory.CreateDirectory(Path.Combine(root, ".git"));
        File.WriteAllText(Path.Combine(root, ".env"), dotEnv);

        return root;
    }

    private static RelayOptions Resolve(string? envValue, string searchFrom) =>
        RelayOptions.FromEnvironment(
            "11111111-2222-3333-4444-555555555555",
            "windows",
            env: name => name == RelayOptions.SecretVariable ? envValue : null,
            searchFrom: searchFrom);

    [Fact]
    public void PrefersTheEnvironmentVariable()
    {
        Checkout(
            $"{RelayOptions.DotEnvKey}=from-dotenv\n");

        Assert.Equal("from-env-var", Resolve("from-env-var", _dir).Secret);
    }

    [Fact]
    public void FallsBackToADotEnvFurtherUpTheTree()
    {
        Checkout(
            $"{RelayOptions.DotEnvKey}=from-dotenv\n");
        var nested = Directory.CreateDirectory(Path.Combine(_dir, "windows", "bin", "Debug")).FullName;

        // The tests, the harness and a git worktree all sit at different depths,
        // so the walk must not assume one.
        Assert.Equal("from-dotenv", Resolve(null, nested).Secret);
    }

    [Fact]
    public void IgnoresCommentsAndStripsQuotes()
    {
        Checkout(
            $"# {RelayOptions.DotEnvKey}=commented-out\nOTHER=x\n{RelayOptions.DotEnvKey}=\"quoted\"\n");

        Assert.Equal("quoted", Resolve(null, _dir).Secret);
    }

    [Fact]
    public void DoesNotMatchAKeyThatMerelyEndsWithOurs()
    {
        Checkout(
            $"OLD_{RelayOptions.DotEnvKey}=wrong\n{RelayOptions.DotEnvKey}=right\n");

        Assert.Equal("right", Resolve(null, _dir).Secret);
    }

    [Fact]
    public void ADotEnvThatIsNotACheckoutsIsIgnored()
    {
        // Without this rule the walk runs to the filesystem root and uses any
        // .env that defines the key. A copy of this repository's .env left in
        // the system temp directory was enough to fail five tests on one machine
        // and pass everywhere else -- and an application taking a secret from a
        // stray file several directories above itself is a surprise however it
        // resolves.
        File.WriteAllText(Path.Combine(_dir, ".env"), $"{RelayOptions.DotEnvKey}=from-a-stray-file\n");

        Assert.Throws<InvalidOperationException>(() => Resolve(null, _dir));
    }

    [Fact]
    public void AWorktreesGitFileCountsAsACheckout()
    {
        // A worktree's .git is a file pointing at the real one, not a directory.
        // Several agents work in worktrees here, and a rule that only recognised
        // directories would quietly stop finding the secret in all of them.
        File.WriteAllText(Path.Combine(_dir, ".git"), "gitdir: /somewhere/else\n");
        File.WriteAllText(Path.Combine(_dir, ".env"), $"{RelayOptions.DotEnvKey}=from-a-worktree\n");

        Assert.Equal("from-a-worktree", Resolve(null, _dir).Secret);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void TreatsAnAbsentOrBlankSecretAsAnError(string? value)
    {
        // No checkout anywhere up the tree from an empty temp dir, so the only
        // source is the variable. A blank one counts as absent: the relay
        // rejects an empty secret, so accepting it would turn a clear error
        // here into an opaque 401 later.
        var error = Assert.Throws<InvalidOperationException>(() => Resolve(value, _dir));

        Assert.Contains(RelayOptions.SecretVariable, error.Message);
    }

    [Fact]
    public void ComputesTheAuthTokenForTheConfiguredDevice()
    {
        Checkout(
            $"{RelayOptions.DotEnvKey}=hypo-test-secret\n");

        var options = Resolve(null, _dir);

        Assert.Equal(RelayAuthToken.Compute("hypo-test-secret", options.DeviceId), options.AuthToken);
    }

    [Fact]
    public void DefaultsToTheDeployedRelay()
    {
        Checkout(
            $"{RelayOptions.DotEnvKey}=s\n");

        Assert.Equal("wss://hypo.fly.dev/ws", Resolve(null, _dir).Endpoint.ToString());
    }
}
