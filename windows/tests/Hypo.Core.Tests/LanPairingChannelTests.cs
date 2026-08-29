using System.Text.Json;
using Hypo.Core.Discovery;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class LanPairingChannelTests
{
    private const string ClientId = "550e8400-e29b-41d4-a716-446655440000";
    private static readonly Guid ServerId = Guid.Parse("bbe296d6-0785-43d2-91b6-b135b72f4c41");

    private static DiscoveredPeer PeerOn(int port) => DiscoveredPeer.FromTxt(
        "server._hypo._tcp.local", "localhost", "127.0.0.1", port,
        new Dictionary<string, string> { ["device_id"] = ServerId.ToString("D") });

    [Fact]
    public async Task AChallengeArrivesAsBareJsonOnTheTextChannel()
    {
        await using var server = new LanWebSocketServer(port: 0);
        var received = new TaskCompletionSource<PairingChallengeMessage>();
        server.PairingMessageReceived += (_, e) =>
        {
            var m = JsonSerializer.Deserialize<PairingChallengeMessage>(e.Json, ProtocolJson.Options);
            if (m is not null) received.TrySetResult(m);
        };
        await server.StartAsync();

        var session = PairingSession.StartInitiator(ClientId, "Test PC");
        var responder = PairingSession.StartResponder(ServerId, "Peer");
        var challenge = session.CreateChallenge(responder.AgreementPublicKey);

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();
        await client.SendPairingAsync(challenge);

        var got = await received.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(challenge.ChallengeId, got.ChallengeId);
        Assert.Equal(challenge.InitiatorDeviceId, got.InitiatorDeviceId);
    }

    [Fact]
    public async Task ThePairingChannelCarriesNoLengthPrefix()
    {
        // The peers send bare JSON. If we prefix it, macOS fails to parse the
        // whole message as JSON and Android's substring match still succeeds but
        // its parse does not — either way the pairing dies silently.
        await using var server = new LanWebSocketServer(port: 0);
        var raw = new TaskCompletionSource<string>();
        server.PairingMessageReceived += (_, e) => raw.TrySetResult(e.Json);
        await server.StartAsync();

        var responder = PairingSession.StartResponder(ServerId, "Peer");
        var challenge = PairingSession.StartInitiator(ClientId, "Test PC")
            .CreateChallenge(responder.AgreementPublicKey);

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();
        await client.SendPairingAsync(challenge);

        var json = await raw.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.StartsWith("{", json, StringComparison.Ordinal);
        Assert.Contains("\"initiator_device_id\"", json, StringComparison.Ordinal);
        Assert.Contains("\"initiator_pub_key\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AnUnprefixedReplyDoesNotFaultTheTransport()
    {
        // The regression Task 15 hit: a raw-JSON ack fed to FrameReader reads
        // '{"ch' as a length of 2,065,851,240 and tears the connection down.
        await using var server = new LanWebSocketServer(port: 0);
        server.PairingMessageReceived += async (_, e) =>
            await server.SendPairingAsync(e.ConnectionId, """{"challenge_id":"x","responder_device_name":"Peer"}""");
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        var pairing = new TaskCompletionSource<string>();
        client.PairingMessageReceived += (_, e) => pairing.TrySetResult(e.Json);
        await client.ConnectAsync();

        var responder = PairingSession.StartResponder(ServerId, "Peer");
        await client.SendPairingAsync(
            PairingSession.StartInitiator(ClientId, "Test PC").CreateChallenge(responder.AgreementPublicKey));

        var json = await pairing.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Contains("challenge_id", json, StringComparison.Ordinal);
        Assert.NotEqual(TransportState.Faulted, client.State);
    }

    [Fact]
    public async Task ClipboardTrafficStillUsesTheFramedBinaryChannel()
    {
        // The split must not disturb the path Task 9 proved.
        await using var server = new LanWebSocketServer(port: 0);
        var received = new TaskCompletionSource<EnvelopeReceivedEventArgs>();
        server.EnvelopeReceived += (_, e) => received.TrySetResult(e);
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();
        var sent = TestEnvelopes.Clipboard(ClientId, [0xDE, 0xAD]);
        await client.SendAsync(sent);

        var got = await received.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(sent.Id, got.Envelope.Id);
    }
}
