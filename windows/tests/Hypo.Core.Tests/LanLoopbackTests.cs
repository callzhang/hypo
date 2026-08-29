using Hypo.Core.Discovery;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class LanLoopbackTests
{
    private const string ClientId = "550e8400-e29b-41d4-a716-446655440000";
    private const string ServerId = "bbe296d6-0785-43d2-91b6-b135b72f4c41";

    private static DiscoveredPeer PeerOn(int port) => DiscoveredPeer.FromTxt(
        "server._hypo._tcp.local",
        "localhost",
        "127.0.0.1",
        port,
        new Dictionary<string, string> { ["device_id"] = ServerId });

    [Fact]
    public async Task TheServerReceivesWhatTheClientSends()
    {
        await using var server = new LanWebSocketServer(ServerId, port: 0);
        var received = new TaskCompletionSource<EnvelopeReceivedEventArgs>();
        server.EnvelopeReceived += (_, e) => received.TrySetResult(e);
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();

        var sent = TestEnvelopes.Clipboard(ClientId, [0xDE, 0xAD, 0xBE, 0xEF]);
        await client.SendAsync(sent);

        var got = await received.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(sent.Id, got.Envelope.Id);
        Assert.Equal([0xDE, 0xAD, 0xBE, 0xEF], got.Envelope.Payload.Ciphertext);
        Assert.Equal(TransportOrigin.Lan, got.Origin);
    }

    [Fact]
    public async Task TheServerLearnsTheClientDeviceIdFromTheHandshake()
    {
        await using var server = new LanWebSocketServer(ServerId, port: 0);
        var received = new TaskCompletionSource<EnvelopeReceivedEventArgs>();
        server.EnvelopeReceived += (_, e) => received.TrySetResult(e);
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();
        await client.SendAsync(TestEnvelopes.Clipboard(ClientId));

        var got = await received.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(ClientId, got.PeerDeviceId);
    }

    [Fact]
    public async Task SeveralEnvelopesInOneReadAreAllDelivered()
    {
        await using var server = new LanWebSocketServer(ServerId, port: 0);
        var received = new List<SyncEnvelope>();
        var done = new TaskCompletionSource();
        server.EnvelopeReceived += (_, e) =>
        {
            lock (received)
            {
                received.Add(e.Envelope);
                if (received.Count == 3) done.TrySetResult();
            }
        };
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();

        for (var i = 0; i < 3; i++)
        {
            await client.SendAsync(TestEnvelopes.Clipboard(ClientId, [(byte)i]));
        }

        await done.Task.WaitAsync(TimeSpan.FromSeconds(10));

        lock (received)
        {
            Assert.Equal(3, received.Count);
            Assert.Equal([0, 1, 2], received.Select(e => e.Payload.Ciphertext[0]));
        }
    }

    [Fact]
    public async Task ConnectingReportsTheStateTransitions()
    {
        await using var server = new LanWebSocketServer(ServerId, port: 0);
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        var states = new List<TransportState>();
        client.StateChanged += (_, e) => { lock (states) { states.Add(e.State); } };

        await client.ConnectAsync();

        lock (states)
        {
            Assert.Equal([TransportState.Connecting, TransportState.Connected], states);
        }
    }

    [Fact]
    public async Task ConnectingToANonListeningPortFaults()
    {
        // Port 1 is privileged and nothing listens there in a test run.
        await using var client = new LanWebSocketClient(PeerOn(1), ClientId);
        var faulted = new TaskCompletionSource<TransportStateChangedEventArgs>();
        client.StateChanged += (_, e) => { if (e.State == TransportState.Faulted) faulted.TrySetResult(e); };

        await Assert.ThrowsAnyAsync<Exception>(() => client.ConnectAsync());

        var args = await faulted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.NotNull(args.Error);
    }
}
