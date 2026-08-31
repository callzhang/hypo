using System.Text.Json;
using Hypo.Core.Abstractions;
using System.Net.Http;
using Hypo.Core.Discovery;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;
using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class PairingViewModelTests
{
    private const string LocalId = "11111111-2222-3333-4444-555555555555";
    private static readonly Guid PeerId = Guid.Parse("bbe296d6-0785-43d2-91b6-b135b72f4c41");

    private static DiscoveredPeer Peer(
        string deviceId, int port = 7010, byte[]? publicKey = null, string name = "OPPO PLP110") =>
        DiscoveredPeer.FromTxt(
            instanceName: $"{name}._hypo._tcp.local",
            host: "localhost",
            address: "127.0.0.1",
            port: port,
            txt: publicKey is null
                ? new Dictionary<string, string> { ["device_id"] = deviceId }
                : new Dictionary<string, string>
                {
                    ["device_id"] = deviceId,
                    ["pub_key"] = Convert.ToBase64String(publicKey),
                });

    private static PairingViewModel Build(ISecretStore store) =>
        new(store, new LanPairingCoordinator(store), LocalId, "Test PC");

    [Fact]
    public void OffersADiscoveredPeer()
    {
        var model = Build(new InMemorySecretStore());
        model.Observe(Peer(PeerId.ToString(), publicKey: new byte[32]));

        var peer = Assert.Single(model.Peers);
        Assert.Equal("OPPO PLP110", peer.DisplayName);
        Assert.True(peer.CanPair);
    }

    [Fact]
    public void MarksAPeerItIsAlreadyPairedWith()
    {
        var store = new InMemorySecretStore();
        store.Write(PeerId.ToString(), new byte[32]);

        var model = Build(store);
        model.Observe(Peer(PeerId.ToString(), publicKey: new byte[32]));

        var peer = Assert.Single(model.Peers);
        Assert.True(peer.AlreadyPaired);
        Assert.False(peer.CanPair);
    }

    [Fact]
    public void NeverOffersThisDevice()
    {
        // We advertise on the network we browse, so we see ourselves.
        var model = Build(new InMemorySecretStore());
        model.Observe(Peer(LocalId.ToUpperInvariant(), publicKey: new byte[32]));

        Assert.Empty(model.Peers);
    }

    [Fact]
    public void CannotPairWithAPeerOfferingNoKey()
    {
        var model = Build(new InMemorySecretStore());
        model.Observe(Peer(PeerId.ToString()));

        Assert.False(Assert.Single(model.Peers).CanPair);
    }

    [Fact]
    public void DoesNotListTheSamePeerTwiceWhenItReannounces()
    {
        var model = Build(new InMemorySecretStore());
        model.Observe(Peer(PeerId.ToString(), publicKey: new byte[32]));
        model.Observe(Peer(PeerId.ToString(), port: 7011, publicKey: new byte[32]));

        Assert.Single(model.Peers);
        Assert.Equal(7011, Assert.Single(model.Peers).Peer.Port);
    }

    [Theory]
    [InlineData(PairingOutcome.NoReply, "did not answer")]
    [InlineData(PairingOutcome.AckRejected, "did not verify")]
    [InlineData(PairingOutcome.PeerAdvertisesNoKey, "not offering to pair")]
    public void SaysWhatWentWrongRatherThanJustThatSomethingDid(PairingOutcome outcome, string expected)
    {
        // These mean very different things. The first is usually the app not
        // being open on the phone; the second is a peer that is not who it says.
        // Collapsing both into "pairing failed" throws that away exactly when the
        // user needs it.
        var message = PairingViewModel.Describe(new PairingResult(outcome), "OPPO PLP110");

        Assert.Contains(expected, message, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("OPPO PLP110", message, StringComparison.Ordinal);
    }

    [Fact]
    public void SaysWhoItPairedWith()
    {
        var message = PairingViewModel.Describe(
            new PairingResult(PairingOutcome.Paired, PeerId.ToString(), "OPPO PLP110"), "ignored");

        Assert.Contains("Paired with OPPO PLP110", message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task PairingMakesThePeerASyncTargetWithoutARestart()
    {
        // Asking someone to restart the app to sync with a device they just
        // paired would be a strange thing to require.
        var responder = PairingSession.StartResponder(PeerId, "Responding Peer");

        await using var server = new LanWebSocketServer(port: 0);
        server.PairingMessageReceived += async (_, e) =>
        {
            var challenge = JsonSerializer.Deserialize<PairingChallengeMessage>(e.Json, ProtocolJson.Options)!;
            var accepted = responder.AcceptChallenge(challenge)!;
            await server.SendPairingAsync(
                e.ConnectionId, JsonSerializer.Serialize(accepted.Ack, ProtocolJson.Options));
        };
        await server.StartAsync();

        var store = new InMemorySecretStore();
        using var history = new Core.History.ClipboardHistoryStore(":memory:");
        var transport = new RecordingTransport();
        var sync = new Core.Sync.SyncCoordinator(
            new NullClipboard(), transport, store, history, LocalId, "Test PC");

        var model = new PairingViewModel(
            store, new LanPairingCoordinator(store), LocalId, "Test PC", sync);

        model.Observe(Peer(PeerId.ToString(), server.BoundPort, responder.AgreementPublicKey));

        var result = await model.PairAsync(Assert.Single(model.Peers));

        Assert.True(result.Succeeded);
        Assert.Contains(PeerId.ToString(), sync.Peers);
        Assert.True(Assert.Single(model.Peers).AlreadyPaired);
        Assert.Contains("Paired with", model.LastMessage!, StringComparison.Ordinal);
    }

    [Fact]
    public void SaysWhetherAPeerIsAlreadyPaired()
    {
        // This existed on the model and never reached the screen: the pairing
        // window showed a paired device and a new one identically until a
        // screenshot made it obvious.
        var store = new InMemorySecretStore();
        store.Write(PeerId.ToString(), new byte[32]);

        var model = Build(store);
        model.Observe(Peer(PeerId.ToString(), publicKey: new byte[32]));

        Assert.Equal("Already paired", Assert.Single(model.Peers).Status);
    }

    [Fact]
    public void SaysWhenAPeerIsReadyToPair()
    {
        var model = Build(new InMemorySecretStore());
        model.Observe(Peer(PeerId.ToString(), publicKey: new byte[32]));

        Assert.Equal("Ready to pair", Assert.Single(model.Peers).Status);
    }

    [Fact]
    public void SaysWhatToDoAboutAPeerOfferingNoKey()
    {
        var model = Build(new InMemorySecretStore());
        model.Observe(Peer(PeerId.ToString()));

        Assert.Contains("open Hypo on it", Assert.Single(model.Peers).Status, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task SaysSoRatherThanFailingWhenThereAreNoRelayCredentials()
    {
        // A build with no relay secret can still pair over the LAN. Offering a
        // code and then throwing would be worse than saying it is unavailable.
        var model = Build(new InMemorySecretStore());

        Assert.False(model.CanPairByCode);

        var result = await model.UseCodeAsync("123456");

        Assert.False(result.Succeeded);
        Assert.Contains("relay credentials", model.LastMessage!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AsksForACodeBeforeTryingToUseOne()
    {
        var store = new InMemorySecretStore();
        var model = new PairingViewModel(
            store,
            new LanPairingCoordinator(store),
            LocalId,
            "Test PC",
            sync: null,
            remote: new RemotePairingCoordinator(
                new RelayPairingClient(new HttpClient(new UnreachableRelay())), store));

        var result = await model.UseCodeAsync("   ");

        Assert.False(result.Succeeded);
        Assert.Contains("Type the code", model.LastMessage!, StringComparison.Ordinal);
    }

    /// <summary>Fails every request, as an unreachable relay does.</summary>
    private sealed class UnreachableRelay : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken ct) =>
            throw new HttpRequestException("no relay here");
    }

    private sealed class NullClipboard : Core.Sync.IClipboard
    {
        public event EventHandler<Core.Sync.ClipboardContent>? ContentChanged;

        public Task<Core.Sync.ClipboardContent?> GetAsync(CancellationToken ct = default)
        {
            _ = ContentChanged;
            return Task.FromResult<Core.Sync.ClipboardContent?>(null);
        }

        public Task SetAsync(Core.Sync.ClipboardContent content, CancellationToken ct = default) =>
            Task.CompletedTask;
    }

    private sealed class RecordingTransport : ISyncTransport
    {
        public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;
        public event EventHandler<TransportStateChangedEventArgs>? StateChanged;

        public TransportState State => TransportState.Connected;

        public Task ConnectAsync(CancellationToken ct = default)
        {
            _ = EnvelopeReceived;
            _ = StateChanged;
            return Task.CompletedTask;
        }

        public Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default) => Task.CompletedTask;

        public Task DisconnectAsync(CancellationToken ct = default) => Task.CompletedTask;

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
