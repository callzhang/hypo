using Hypo.Core.Abstractions;
using Hypo.Core.Pairing;

namespace Hypo.Core.Tests;

/// <summary>
/// Pairing two devices that are never on the same network, through a code the
/// user carries between them. Both sides run against a stand-in relay that
/// implements the same six-digit-code protocol.
/// </summary>
public class RemotePairingTests
{
    private static readonly Guid ShowerId = Guid.Parse("bbe296d6-0785-43d2-91b6-b135b72f4c41");
    private const string TyperId = "11111111-2222-3333-4444-555555555555";

    private static (RelayPairingClient Client, StubRelayPairingServer Server) Build()
    {
        var server = new StubRelayPairingServer();
        var http = new HttpClient(server) { Timeout = TimeSpan.FromSeconds(10) };

        return (new RelayPairingClient(http, new Uri("https://relay.test/")), server);
    }

    [Fact]
    public async Task TwoDevicesPairThroughACode()
    {
        var (client, _) = Build();

        var showerStore = new InMemorySecretStore();
        var typerStore = new InMemorySecretStore();

        var shower = new RemotePairingCoordinator(client, showerStore)
        {
            PollInterval = TimeSpan.FromMilliseconds(20),
        };
        var typer = new RemotePairingCoordinator(client, typerStore)
        {
            PollInterval = TimeSpan.FromMilliseconds(20),
        };

        var codeReady = new TaskCompletionSource<PairingCode>(TaskCreationOptions.RunContinuationsAsynchronously);

        var showing = shower.ShowCodeAsync(ShowerId, "The Phone", codeReady.SetResult);
        var code = await codeReady.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(6, code.Code.Length);

        var using_ = await typer.UseCodeAsync(code.Code, TyperId, "The PC");
        var shown = await showing.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.True(using_.Succeeded);
        Assert.True(shown.Succeeded);

        Assert.Equal(ShowerId.ToString(), using_.PeerDeviceId);
        Assert.Equal("The Phone", using_.PeerDeviceName);
        Assert.Equal(TyperId, shown.PeerDeviceId);
        Assert.Equal("The PC", shown.PeerDeviceName);
    }

    [Fact]
    public async Task BothSidesEndUpWithTheSameKey()
    {
        // The whole point. Different keys means every message after this fails
        // to decrypt, with nothing to say why.
        var (client, _) = Build();

        var showerStore = new InMemorySecretStore();
        var typerStore = new InMemorySecretStore();

        var shower = new RemotePairingCoordinator(client, showerStore)
        {
            PollInterval = TimeSpan.FromMilliseconds(20),
        };
        var typer = new RemotePairingCoordinator(client, typerStore)
        {
            PollInterval = TimeSpan.FromMilliseconds(20),
        };

        var codeReady = new TaskCompletionSource<PairingCode>(TaskCreationOptions.RunContinuationsAsynchronously);
        var showing = shower.ShowCodeAsync(ShowerId, "The Phone", codeReady.SetResult);
        var code = await codeReady.Task.WaitAsync(TimeSpan.FromSeconds(5));

        await typer.UseCodeAsync(code.Code, TyperId, "The PC");
        await showing.WaitAsync(TimeSpan.FromSeconds(10));

        var showerKey = showerStore.Read(TyperId);
        var typerKey = typerStore.Read(ShowerId.ToString());

        Assert.NotNull(showerKey);
        Assert.NotNull(typerKey);
        Assert.Equal(Convert.ToHexString(showerKey!), Convert.ToHexString(typerKey!));
    }

    [Fact]
    public async Task AWrongCodeIsReportedRatherThanHanging()
    {
        // The failure a user is most likely to cause.
        var (client, _) = Build();

        var result = await new RemotePairingCoordinator(client, new InMemorySecretStore())
            .UseCodeAsync("000000", TyperId, "The PC");

        Assert.Equal(PairingOutcome.NoReply, result.Outcome);
    }

    [Fact]
    public async Task AnExpiredCodeStopsWaiting()
    {
        // Bounded by the code's own expiry: once it has expired nothing can
        // arrive, and waiting longer only delays telling the user.
        var (client, server) = Build();
        server.CodeLifetime = TimeSpan.FromMilliseconds(200);

        var coordinator = new RemotePairingCoordinator(client, new InMemorySecretStore())
        {
            PollInterval = TimeSpan.FromMilliseconds(20),
        };

        var codeReady = new TaskCompletionSource<PairingCode>(TaskCreationOptions.RunContinuationsAsynchronously);

        // Nobody ever types it.
        var result = await coordinator
            .ShowCodeAsync(ShowerId, "The Phone", codeReady.SetResult)
            .WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(PairingOutcome.NoReply, result.Outcome);
    }

    [Fact]
    public async Task AChallengeThatDoesNotVerifyLeavesNoKey()
    {
        // Someone answered the code who could not have known the key. Not a
        // network problem, and not something to store a key over.
        var (client, server) = Build();
        server.CorruptChallenge = true;

        var store = new InMemorySecretStore();
        var coordinator = new RemotePairingCoordinator(client, store)
        {
            PollInterval = TimeSpan.FromMilliseconds(20),
        };

        var codeReady = new TaskCompletionSource<PairingCode>(TaskCreationOptions.RunContinuationsAsynchronously);
        var showing = coordinator.ShowCodeAsync(ShowerId, "The Phone", codeReady.SetResult);
        var code = await codeReady.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var typer = new RemotePairingCoordinator(client, new InMemorySecretStore())
        {
            PollInterval = TimeSpan.FromMilliseconds(20),
        };
        _ = typer.UseCodeAsync(code.Code, TyperId, "The PC");

        var result = await showing.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(PairingOutcome.AckRejected, result.Outcome);
        Assert.Null(store.Read(TyperId));
    }

    [Fact]
    public async Task TheCodeIsSixDigits()
    {
        // It is read out loud or typed from a screen. Anything longer or
        // case-sensitive would be a different feature.
        var (client, _) = Build();

        var codeReady = new TaskCompletionSource<PairingCode>(TaskCreationOptions.RunContinuationsAsynchronously);
        var showing = new RemotePairingCoordinator(client, new InMemorySecretStore())
        {
            PollInterval = TimeSpan.FromMilliseconds(20),
        }.ShowCodeAsync(ShowerId, "The Phone", codeReady.SetResult);

        var code = await codeReady.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Matches("^[0-9]{6}$", code.Code);
        Assert.True(code.ExpiresAt > DateTimeOffset.UtcNow);

        _ = showing;
    }
}
