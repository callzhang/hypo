using Hypo.Core.Relay;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

/// <summary>
/// Connects to the deployed relay. Enable with HYPO_LIVE_RELAY=1 and a secret
/// in HYPO_RELAY_AUTH_TOKEN or a repo-root .env.
///
/// The stub in <see cref="CloudWebSocketClientTests"/> cannot catch the class of
/// mistake that matters most here: a misspelled header name, or an HMAC over
/// the wrong string. The stub happily agrees with whatever the client sends.
/// Only the real relay disagrees.
/// </summary>
public class LiveRelayTests
{
    private static bool Enabled => Environment.GetEnvironmentVariable("HYPO_LIVE_RELAY") == "1";

    [SkippableFact]
    public async Task TheRealRelayAcceptsOurCredentials()
    {
        Skip.IfNot(Enabled, "Set HYPO_LIVE_RELAY=1 to connect to wss://hypo.fly.dev/ws.");

        var options = RelayOptions.FromEnvironment(
            "11111111-2222-3333-4444-555555555555",
            "windows",
            searchFrom: AppContext.BaseDirectory);

        await using var client = new CloudWebSocketClient(options);
        await client.ConnectAsync();

        Assert.Equal(TransportState.Connected, client.State);

        // Nothing arrives on connect, so staying connected is the assertion.
        await Task.Delay(TimeSpan.FromSeconds(3));
        Assert.Equal(TransportState.Connected, client.State);
    }

    [SkippableFact]
    public async Task ARejectedTokenFaultsRatherThanHanging()
    {
        Skip.IfNot(Enabled, "Set HYPO_LIVE_RELAY=1 to connect to wss://hypo.fly.dev/ws.");

        var options = new RelayOptions
        {
            Endpoint = new Uri(RelayOptions.DefaultEndpoint),
            Secret = "definitely-not-the-relay-secret",
            DeviceId = "11111111-2222-3333-4444-555555555555",
            Platform = "windows",
        };

        await using var client = new CloudWebSocketClient(options);

        await Assert.ThrowsAnyAsync<Exception>(() => client.ConnectAsync());
        Assert.Equal(TransportState.Faulted, client.State);
    }
}
