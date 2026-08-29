namespace Hypo.Core.Relay;

/// <summary>
/// Everything needed to open a relay connection.
///
/// <para><b>Where the secret comes from, and why this is not the final
/// answer.</b> The relay authenticates every client with one shared secret.
/// Android bakes it into <c>BuildConfig</c> at build time from the repo-root
/// <c>.env</c>. Copying that for Windows would put the secret inside an MSIX
/// that strangers install, where it is a secret only until someone unzips it.
/// This class therefore reads the secret at *run* time — from
/// <c>HYPO_RELAY_AUTH_TOKEN</c>, or from a repo-root <c>.env</c> when running
/// from a source checkout — which is enough for the harness and the tests and
/// commits us to nothing.</para>
///
/// <para>How a shipped Windows build should obtain relay credentials is an
/// open question for the packaging plan. It is written here rather than left
/// implicit so it is a decision someone makes, not a default someone
/// discovers.</para>
/// </summary>
public sealed record RelayOptions
{
    public const string DefaultEndpoint = "wss://hypo.fly.dev/ws";
    public const string SecretVariable = "HYPO_RELAY_AUTH_TOKEN";

    /// <summary>The name the repo-root .env uses, which is not our variable name.</summary>
    public const string DotEnvKey = "RELAY_WS_AUTH_TOKEN";

    public required Uri Endpoint { get; init; }

    public required string Secret { get; init; }

    public required string DeviceId { get; init; }

    public required string Platform { get; init; }

    /// <summary>
    /// How often the socket emits a keepalive frame.
    ///
    /// <para>Fly.io closes idle connections at 900 s
    /// (<c>http_options.idle_timeout</c> in <c>backend/fly.toml</c>) and the
    /// relay never initiates -- it answers a Ping with a Pong and nothing
    /// more. So the client owns liveness. 840 s is what Android uses: far
    /// enough under the ceiling to survive a slow round trip, and long enough
    /// that a phone on an idle link is not woken for nothing.</para>
    /// </summary>
    public TimeSpan KeepAliveInterval { get; init; } = TimeSpan.FromSeconds(840);

    /// <summary>
    /// How long to wait for a Pong before treating the connection as dead. This
    /// is what turns the keepalive from "keep the proxy happy" into "notice when
    /// the relay has gone", which matters because a silently dead socket looks
    /// exactly like an idle one.
    /// </summary>
    public TimeSpan KeepAliveTimeout { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>Delay before the first reconnection attempt; doubles from there.</summary>
    public TimeSpan ReconnectInitialDelay { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>Ceiling for the backoff, so a long outage does not become a long silence.</summary>
    public TimeSpan ReconnectMaxDelay { get; init; } = TimeSpan.FromSeconds(60);

    public string AuthToken => RelayAuthToken.Compute(Secret, DeviceId);

    /// <summary>
    /// Resolves the secret from the environment, falling back to a repo-root
    /// <c>.env</c> found by walking up from <paramref name="searchFrom"/>.
    /// </summary>
    /// <param name="env">
    /// Environment lookup, injected so tests do not have to mutate the process
    /// environment and race each other.
    /// </param>
    public static RelayOptions FromEnvironment(
        string deviceId,
        string platform,
        Func<string, string?>? env = null,
        string? searchFrom = null,
        string? endpoint = null)
    {
        env ??= Environment.GetEnvironmentVariable;

        var secret = Blank(env(SecretVariable))
            ? FindInDotEnv(searchFrom ?? AppContext.BaseDirectory)
            : env(SecretVariable);

        if (Blank(secret))
        {
            throw new InvalidOperationException(
                $"No relay secret. Set {SecretVariable}, or run from a checkout " +
                $"whose root .env defines {DotEnvKey}. An empty value counts as " +
                "absent: the relay rejects an empty secret, so proceeding would " +
                "only turn a clear error here into an opaque 401 later.");
        }

        return new RelayOptions
        {
            Endpoint = new Uri(endpoint ?? DefaultEndpoint),
            Secret = secret!,
            DeviceId = deviceId,
            Platform = platform,
        };
    }

    private static bool Blank(string? value) => string.IsNullOrWhiteSpace(value);

    /// <summary>
    /// Walks up looking for a <c>.env</c> holding <see cref="DotEnvKey"/>. Walks
    /// rather than assuming a fixed depth because the tests, the harness and a
    /// git worktree all sit at different distances from the root.
    /// </summary>
    private static string? FindInDotEnv(string startDirectory)
    {
        var dir = new DirectoryInfo(startDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, ".env");
            if (File.Exists(candidate))
            {
                var value = ReadKey(candidate, DotEnvKey);
                if (!Blank(value))
                {
                    return value;
                }
            }

            dir = dir.Parent;
        }

        return null;
    }

    private static string? ReadKey(string path, string key)
    {
        foreach (var raw in File.ReadLines(path))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#'))
            {
                continue;
            }

            var split = line.IndexOf('=');
            if (split <= 0 || !line.AsSpan(0, split).Trim().SequenceEqual(key))
            {
                continue;
            }

            return line[(split + 1)..].Trim().Trim('"', '\'');
        }

        return null;
    }
}
