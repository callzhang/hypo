using Hypo.Core.Abstractions;
using Hypo.Core.Pairing;
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

    /// <summary>
    /// Holds an idle connection past Fly.io's 900 s ceiling. Enable with
    /// HYPO_LIVE_RELAY_SOAK=1; it takes sixteen minutes by construction.
    ///
    /// The keepalive cannot be unit-tested end to end: ClientWebSocket has no
    /// manual ping and Kestrel does not surface the ones the framework sends,
    /// so a stub can only ever confirm that we set a number. Whether the number
    /// is right is a question only an idle socket and a real proxy can answer.
    /// </summary>
    [SkippableFact]
    public async Task SurvivesLongerThanTheRelayIdleTimeout()
    {
        Skip.IfNot(
            Environment.GetEnvironmentVariable("HYPO_LIVE_RELAY_SOAK") == "1",
            "Set HYPO_LIVE_RELAY_SOAK=1; this test idles for sixteen minutes.");

        var options = RelayOptions.FromEnvironment(
            "11111111-2222-3333-4444-555555555555",
            "windows",
            searchFrom: AppContext.BaseDirectory);

        await using var client = new CloudWebSocketClient(options);
        await client.ConnectAsync();

        // Sixteen minutes: past the 900 s ceiling, and past the 840 s keepalive
        // that is supposed to prevent it.
        await Task.Delay(TimeSpan.FromMinutes(16));

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

    /// <summary>
    /// Runs both halves of a code pairing against the deployed relay.
    ///
    /// <para>The stub in RemotePairingTests can agree with the client while both
    /// disagree with the real thing -- a wrong path, a renamed field, a role
    /// name taken at face value. Only the relay settles that.</para>
    /// </summary>
    [SkippableFact]
    public async Task TheRealRelayBrokersACodePairing()
    {
        Skip.IfNot(Enabled, "Set HYPO_LIVE_RELAY=1 to pair through wss://hypo.fly.dev.");

        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        var relay = new RelayPairingClient(http);

        var showerStore = new InMemorySecretStore();
        var typerStore = new InMemorySecretStore();

        var shower = new RemotePairingCoordinator(relay, showerStore);
        var typer = new RemotePairingCoordinator(relay, typerStore);

        var showerId = Guid.NewGuid();
        var typerId = Guid.NewGuid().ToString();

        var codeReady = new TaskCompletionSource<PairingCode>(TaskCreationOptions.RunContinuationsAsynchronously);
        var showing = shower.ShowCodeAsync(showerId, "Live Test Phone", codeReady.SetResult);

        var code = await codeReady.Task.WaitAsync(TimeSpan.FromSeconds(20));
        Assert.Matches("^[0-9]{6}$", code.Code);

        var used = await typer.UseCodeAsync(code.Code, typerId, "Live Test PC");
        var shown = await showing.WaitAsync(TimeSpan.FromSeconds(60));

        Assert.True(used.Succeeded, $"typing the code: {used.Outcome}");
        Assert.True(shown.Succeeded, $"showing the code: {shown.Outcome}");

        // The only thing that matters afterwards: both ended up with the same key.
        Assert.Equal(
            Convert.ToHexString(showerStore.Read(typerId)!),
            Convert.ToHexString(typerStore.Read(showerId.ToString())!));
    }
}
