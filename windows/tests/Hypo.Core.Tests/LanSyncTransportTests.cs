using Hypo.Core.Discovery;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class LanSyncTransportTests
{
    private const string LocalId = "11111111-2222-3333-4444-555555555555";
    private const string PeerId = "bbe296d6-0785-43d2-91b6-b135b72f4c41";

    /// <summary>Discovery the test drives, so no test depends on a real network.</summary>
    private sealed class FakeDiscovery : IPeerDiscovery
    {
        public event EventHandler<DiscoveredPeer>? PeerDiscovered;

        public List<(string Name, int Port, IReadOnlyDictionary<string, string> Txt)> Advertised { get; } = [];

        public bool Browsing { get; private set; }

        public IReadOnlyCollection<DiscoveredPeer> KnownPeers => [];

        public Task AdvertiseAsync(
            string deviceName, int port, IReadOnlyDictionary<string, string> txt, CancellationToken ct = default)
        {
            Advertised.Add((deviceName, port, txt));
            return Task.CompletedTask;
        }

        public Task StartBrowsingAsync(CancellationToken ct = default)
        {
            Browsing = true;
            return Task.CompletedTask;
        }

        public void Announce(DiscoveredPeer peer) => PeerDiscovered?.Invoke(this, peer);

        public int Refreshes;

        /// <summary>Re-announces what it has seen, the way a real query does.</summary>
        public List<DiscoveredPeer> Standing { get; } = [];

        public void Refresh()
        {
            Interlocked.Increment(ref Refreshes);

            foreach (var peer in Standing.ToArray())
            {
                Announce(peer);
            }
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private static DiscoveredPeer Peer(int port, string deviceId = PeerId) => DiscoveredPeer.FromTxt(
        instanceName: $"{deviceId}._hypo._tcp.local",
        host: "localhost",
        address: "127.0.0.1",
        port: port,
        txt: new Dictionary<string, string> { ["device_id"] = deviceId });

    private static SyncEnvelope Envelope(string? target = PeerId) => new()
    {
        Id = Guid.NewGuid(),
        Timestamp = DateTimeOffset.UnixEpoch,
        Type = MessageType.Clipboard,
        Payload = new EnvelopePayload
        {
            ContentType = ContentType.Text,
            Ciphertext = [1, 2, 3],
            DeviceId = LocalId,
            Target = target,
            Encryption = new EncryptionMetadata { Nonce = new byte[12], Tag = new byte[16] },
        },
    };

    private static async Task<bool> Eventually(Func<bool> condition, TimeSpan? within = null)
    {
        var deadline = DateTime.UtcNow + (within ?? TimeSpan.FromSeconds(5));
        while (DateTime.UtcNow < deadline)
        {
            if (condition())
            {
                return true;
            }

            await Task.Delay(25);
        }

        return condition();
    }

    [Fact]
    public async Task AdvertisesTheBoundPortRatherThanTheConfiguredOne()
    {
        // The server falls back to an ephemeral port when 7010 is taken, and a
        // peer that dials the configured one simply never connects.
        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);

        await transport.ConnectAsync();

        var advertised = Assert.Single(discovery.Advertised);
        Assert.NotEqual(0, advertised.Port);
        Assert.Equal(LocalId, advertised.Txt["device_id"]);
        Assert.True(discovery.Browsing);
    }

    [Fact]
    public async Task DialsAPairedPeerAndSendsToIt()
    {
        await using var peerServer = new LanWebSocketServer(port: 0);
        var received = new TaskCompletionSource<SyncEnvelope>(TaskCreationOptions.RunContinuationsAsynchronously);
        peerServer.EnvelopeReceived += (_, e) => received.TrySetResult(e.Envelope);
        await peerServer.StartAsync();

        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);
        await transport.ConnectAsync();

        discovery.Announce(Peer(peerServer.BoundPort));

        Assert.True(await Eventually(() => transport.State == TransportState.Connected),
            "the peer never became dialable");

        await transport.SendAsync(Envelope());

        Assert.Equal(LocalId, (await received.Task.WaitAsync(TimeSpan.FromSeconds(5))).Payload.DeviceId);
    }

    [Fact]
    public async Task IgnoresPeersItIsNotPairedWith()
    {
        // Dialling every device on the network would be both rude and useless:
        // without a key we could not read anything it sent.
        await using var peerServer = new LanWebSocketServer(port: 0);
        await peerServer.StartAsync();

        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => false);
        await transport.ConnectAsync();

        discovery.Announce(Peer(peerServer.BoundPort));
        await Task.Delay(400);

        Assert.Empty(transport.ConnectedPeers);
        Assert.Equal(TransportState.Disconnected, transport.State);
    }

    [Fact]
    public async Task IgnoresItsOwnAdvertisement()
    {
        // We advertise on the same network we browse, so we see ourselves.
        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);
        await transport.ConnectAsync();

        discovery.Announce(Peer(9999, deviceId: LocalId.ToUpperInvariant()));
        await Task.Delay(300);

        Assert.Empty(transport.ConnectedPeers);
    }

    [Fact]
    public async Task ReportsAPeerItHasNoRouteToRatherThanFailingOpaquely()
    {
        // This is the signal DualSyncTransport falls back to the relay on.
        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);
        await transport.ConnectAsync();

        var error = await Assert.ThrowsAsync<PeerUnreachableException>(
            () => transport.SendAsync(Envelope()));

        Assert.Equal(PeerId, error.PeerDeviceId);
    }

    [Fact]
    public async Task ReportsAnEnvelopeWithNoTargetAsUnreachable()
    {
        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);
        await transport.ConnectAsync();

        await Assert.ThrowsAsync<PeerUnreachableException>(
            () => transport.SendAsync(Envelope(target: null)));
    }

    [Fact]
    public async Task StaysConnectedWhileAnotherPeerRemains()
    {
        // One phone leaving the network must not push the rest onto the relay.
        const string SecondPeer = "cc000000-0000-0000-0000-000000000002";

        await using var firstServer = new LanWebSocketServer(port: 0);
        await firstServer.StartAsync();
        await using var secondServer = new LanWebSocketServer(port: 0);
        await secondServer.StartAsync();

        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);
        await transport.ConnectAsync();

        discovery.Announce(Peer(firstServer.BoundPort));
        discovery.Announce(Peer(secondServer.BoundPort, SecondPeer));

        Assert.True(await Eventually(() => transport.ConnectedPeers.Count == 2));

        await firstServer.DisposeAsync();

        Assert.True(await Eventually(() => transport.ConnectedPeers.Count == 1));
        Assert.Equal(TransportState.Connected, transport.State);
    }

    [Fact]
    public async Task ReceivesOnItsOwnServer()
    {
        // A peer that discovers us first dials in; a transport that only dialled
        // out would never hear from it.
        var discovery = new FakeDiscovery();
        var server = new LanWebSocketServer(port: 0);
        await using var transport = new LanSyncTransport(discovery, server, LocalId, "Test PC", _ => true);
        await transport.ConnectAsync();

        var received = new TaskCompletionSource<EnvelopeReceivedEventArgs>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        transport.EnvelopeReceived += (_, e) => received.TrySetResult(e);

        await using var dialer = new LanWebSocketClient(
            Peer(server.BoundPort, PeerId) with { Address = "127.0.0.1", Port = server.BoundPort },
            PeerId);
        await dialer.ConnectAsync();
        await dialer.SendAsync(Envelope(target: LocalId));

        var envelope = await received.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TransportOrigin.Lan, envelope.Origin);
    }

    [Fact]
    public async Task DoesNotRefuseToStartWhenNobodyIsOnTheNetwork()
    {
        // A client that waited for a peer would fail to start on a network where
        // only the relay is reachable.
        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);

        await transport.ConnectAsync();

        Assert.Equal(TransportState.Disconnected, transport.State);
    }

    [Fact]
    public async Task DialsAPeerOnceEvenWhenItIsAnnouncedRepeatedly()
    {
        // mDNS re-announces, and a device republishing under a changed instance
        // name looks like a fresh discovery. Seen live: one phone produced two
        // "connected" lines for the same address and port.
        await using var peerServer = new LanWebSocketServer(port: 0);
        await peerServer.StartAsync();

        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);
        await transport.ConnectAsync();

        var connections = 0;
        transport.PeerConnected += (_, _) => Interlocked.Increment(ref connections);

        for (var i = 0; i < 5; i++)
        {
            discovery.Announce(Peer(peerServer.BoundPort) with { InstanceName = $"instance-{i}" });
        }

        Assert.True(await Eventually(() => transport.ConnectedPeers.Count == 1));
        await Task.Delay(500);

        Assert.Single(transport.ConnectedPeers);
        Assert.Equal(1, connections);
    }

    [Fact]
    public async Task RetriesAPeerThatRefusedTheFirstDial()
    {
        // A stale record outlives the process that published it. Failing once
        // must not blacklist the device: it may come back on the same port.
        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);
        await transport.ConnectAsync();

        // Nothing is listening on port 1.
        discovery.Announce(Peer(1));
        await Task.Delay(500);
        Assert.Empty(transport.ConnectedPeers);

        await using var peerServer = new LanWebSocketServer(port: 0);
        await peerServer.StartAsync();
        discovery.Announce(Peer(peerServer.BoundPort));

        Assert.True(await Eventually(() => transport.ConnectedPeers.Count == 1),
            "a failed dial left the peer permanently unreachable");
    }

    [Fact]
    public async Task PicksUpAnAnnouncementThatArrivedWhileItWasStillDialling()
    {
        // The case Windows CI found. Connecting to a dead port is slow enough
        // there that the follow-up announcement always landed mid-dial, and a
        // plain in-flight guard dropped it -- leaving the peer unreachable until
        // some later announcement that might never come.
        await using var peerServer = new LanWebSocketServer(port: 0);
        await peerServer.StartAsync();

        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true);
        await transport.ConnectAsync();

        // Both announcements without waiting: the second necessarily arrives
        // while the first dial is still in flight.
        discovery.Announce(Peer(1));
        discovery.Announce(Peer(peerServer.BoundPort));

        Assert.True(await Eventually(() => transport.ConnectedPeers.Count == 1, TimeSpan.FromSeconds(30)),
            "the announcement that arrived mid-dial was dropped");
    }

    [Fact]
    public async Task AsksTheNetworkAgainOnAnInterval()
    {
        // A peer already present when we started never announces again, and one
        // whose connection dropped is forgotten with nothing to trigger a
        // re-dial. Both look the same to a user: the LAN quietly stops being
        // used and everything goes through the relay.
        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true,
            rediscoveryInterval: TimeSpan.FromMilliseconds(60));

        await transport.ConnectAsync();

        Assert.True(await Eventually(() => Volatile.Read(ref discovery.Refreshes) >= 3),
            $"expected repeated refreshes, saw {discovery.Refreshes}");
    }

    [Fact]
    public async Task RedialsAPeerAfterItsConnectionDrops()
    {
        var peerServer = new LanWebSocketServer(port: 0);
        await peerServer.StartAsync();

        var discovery = new FakeDiscovery();
        await using var transport = new LanSyncTransport(
            discovery, new LanWebSocketServer(port: 0), LocalId, "Test PC", _ => true,
            rediscoveryInterval: TimeSpan.FromMilliseconds(100));
        await transport.ConnectAsync();

        var peer = Peer(peerServer.BoundPort);
        discovery.Standing.Add(peer);
        discovery.Announce(peer);

        Assert.True(await Eventually(() => transport.ConnectedPeers.Count == 1));

        // The peer goes away and comes back on the same port, as a phone leaving
        // and rejoining a network does.
        await peerServer.DisposeAsync();
        Assert.True(await Eventually(() => transport.ConnectedPeers.Count == 0));

        await using var restarted = new LanWebSocketServer(peer.Port);
        await restarted.StartAsync();

        Assert.True(await Eventually(() => transport.ConnectedPeers.Count == 1, TimeSpan.FromSeconds(15)),
            "the peer never came back without a fresh announcement");
    }
}
