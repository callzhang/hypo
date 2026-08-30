using System.Text.Json;
using Hypo.Core.Abstractions;
using Hypo.Core.Discovery;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class LanPairingCoordinatorTests
{
    private const string LocalId = "11111111-2222-3333-4444-555555555555";
    private static readonly Guid PeerId = Guid.Parse("bbe296d6-0785-43d2-91b6-b135b72f4c41");

    private static DiscoveredPeer Peer(int port, byte[]? publicKey) => DiscoveredPeer.FromTxt(
        instanceName: "peer._hypo._tcp.local",
        host: "localhost",
        address: "127.0.0.1",
        port: port,
        txt: publicKey is null
            ? new Dictionary<string, string> { ["device_id"] = PeerId.ToString() }
            : new Dictionary<string, string>
            {
                ["device_id"] = PeerId.ToString(),
                ["pub_key"] = Convert.ToBase64String(publicKey),
            });

    [Fact]
    public async Task PairsWithARespondingPeerAndKeepsTheKey()
    {
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
        var coordinator = new LanPairingCoordinator(store);

        var result = await coordinator.PairAsync(
            Peer(server.BoundPort, responder.AgreementPublicKey), LocalId, "Test PC",
            timeout: TimeSpan.FromSeconds(10));

        Assert.True(result.Succeeded);
        Assert.Equal(PeerId.ToString(), result.PeerDeviceId);
        Assert.Equal("Responding Peer", result.PeerDeviceName);

        // The key has to outlive the handshake or the next process cannot decrypt
        // anything, which is the failure Plan 3 was written to fix.
        Assert.NotNull(store.Read(result.PeerDeviceId!));
    }

    [Fact]
    public async Task ReportsAPeerThatAdvertisesNoKeyWithoutDialling()
    {
        var coordinator = new LanPairingCoordinator(new InMemorySecretStore());

        // Port 1 would refuse the connection; reaching it at all would be the bug.
        var result = await coordinator.PairAsync(Peer(1, publicKey: null), LocalId, "Test PC");

        Assert.Equal(PairingOutcome.PeerAdvertisesNoKey, result.Outcome);
    }

    [Fact]
    public async Task ReportsSilenceRatherThanHangingWhenNoAckArrives()
    {
        var responder = PairingSession.StartResponder(PeerId, "Silent Peer");

        await using var server = new LanWebSocketServer(port: 0);
        await server.StartAsync();

        var coordinator = new LanPairingCoordinator(new InMemorySecretStore());

        var result = await coordinator.PairAsync(
            Peer(server.BoundPort, responder.AgreementPublicKey), LocalId, "Test PC",
            timeout: TimeSpan.FromMilliseconds(500));

        Assert.Equal(PairingOutcome.NoReply, result.Outcome);
    }

    [Fact]
    public async Task KeepsWaitingThroughAMessageItCannotParse()
    {
        // A peer that says something unexpected before answering must not fail
        // the pairing: the shipping clients send more than one kind of message
        // on this channel.
        var responder = PairingSession.StartResponder(PeerId, "Chatty Peer");

        await using var server = new LanWebSocketServer(port: 0);
        server.PairingMessageReceived += async (_, e) =>
        {
            await server.SendPairingAsync(e.ConnectionId, """{"hello":"not an ack"}""");

            var challenge = JsonSerializer.Deserialize<PairingChallengeMessage>(e.Json, ProtocolJson.Options)!;
            var accepted = responder.AcceptChallenge(challenge)!;
            await server.SendPairingAsync(
                e.ConnectionId, JsonSerializer.Serialize(accepted.Ack, ProtocolJson.Options));
        };
        await server.StartAsync();

        var coordinator = new LanPairingCoordinator(new InMemorySecretStore());

        var result = await coordinator.PairAsync(
            Peer(server.BoundPort, responder.AgreementPublicKey), LocalId, "Test PC",
            timeout: TimeSpan.FromSeconds(10));

        Assert.True(result.Succeeded);
    }

    [Fact]
    public async Task RejectsAnAckThatDoesNotVerify()
    {
        // A tampered acknowledgement must not produce a stored key. The GCM tag
        // is the only thing standing between a pairing and whoever answered
        // first on that port.
        var responder = PairingSession.StartResponder(PeerId, "Real Peer");

        await using var server = new LanWebSocketServer(port: 0);
        server.PairingMessageReceived += async (_, e) =>
        {
            var challenge = JsonSerializer.Deserialize<PairingChallengeMessage>(e.Json, ProtocolJson.Options)!;
            var accepted = responder.AcceptChallenge(challenge)!;

            var tampered = accepted.Ack with { Tag = Flip(accepted.Ack.Tag) };

            await server.SendPairingAsync(
                e.ConnectionId, JsonSerializer.Serialize(tampered, ProtocolJson.Options));
        };
        await server.StartAsync();

        var store = new InMemorySecretStore();
        var coordinator = new LanPairingCoordinator(store);

        var result = await coordinator.PairAsync(
            Peer(server.BoundPort, responder.AgreementPublicKey), LocalId, "Test PC",
            timeout: TimeSpan.FromSeconds(10));

        Assert.Equal(PairingOutcome.AckRejected, result.Outcome);
        Assert.Null(store.Read(PeerId.ToString()));
    }

    private static byte[] Flip(byte[] bytes)
    {
        var copy = (byte[])bytes.Clone();
        copy[0] ^= 0xFF;
        return copy;
    }
}
