using Hypo.Core.Protocol;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class DualSyncTransportTests
{
    /// <summary>A transport whose state the test drives directly.</summary>
    private sealed class FakeTransport(TransportOrigin origin) : ISyncTransport
    {
        public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;
        public event EventHandler<TransportStateChangedEventArgs>? StateChanged;

        public TransportState State { get; private set; } = TransportState.Disconnected;

        public List<SyncEnvelope> Sent { get; } = [];

        public bool FailToConnect { get; set; }

        public void SetState(TransportState state)
        {
            State = state;
            StateChanged?.Invoke(this, new TransportStateChangedEventArgs(state, null));
        }

        public void Receive(SyncEnvelope envelope) =>
            EnvelopeReceived?.Invoke(this, new EnvelopeReceivedEventArgs(envelope, "peer", origin));

        public Task ConnectAsync(CancellationToken ct = default)
        {
            if (FailToConnect)
            {
                SetState(TransportState.Faulted);
                throw new IOException("unreachable");
            }

            SetState(TransportState.Connected);
            return Task.CompletedTask;
        }

        public Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default)
        {
            Sent.Add(envelope);
            return Task.CompletedTask;
        }

        public Task DisconnectAsync(CancellationToken ct = default)
        {
            SetState(TransportState.Disconnected);
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private static SyncEnvelope Envelope(Guid? id = null) => new()
    {
        Id = id ?? Guid.NewGuid(),
        Timestamp = DateTimeOffset.UtcNow,
        Type = MessageType.Clipboard,
        Payload = new EnvelopePayload
        {
            ContentType = ContentType.Text,
            Ciphertext = [1, 2, 3],
            DeviceId = "bbe296d6-0785-43d2-91b6-b135b72f4c41",
            Encryption = new EncryptionMetadata { Nonce = new byte[12], Tag = new byte[16] },
        },
    };

    [Fact]
    public async Task PrefersTheLanWhenBothAreUp()
    {
        var lan = new FakeTransport(TransportOrigin.Lan);
        var cloud = new FakeTransport(TransportOrigin.Cloud);
        await using var dual = new DualSyncTransport(lan, cloud);
        await dual.ConnectAsync();

        await dual.SendAsync(Envelope());

        Assert.Single(lan.Sent);
        Assert.Empty(cloud.Sent);
        Assert.Equal(TransportOrigin.Lan, dual.PreferredOrigin);
    }

    [Fact]
    public async Task FallsBackToTheRelayWhenTheLanIsDown()
    {
        var lan = new FakeTransport(TransportOrigin.Lan) { FailToConnect = true };
        var cloud = new FakeTransport(TransportOrigin.Cloud);
        await using var dual = new DualSyncTransport(lan, cloud);

        // A LAN that cannot be reached must not stop the relay from connecting:
        // having one channel is the whole point of having two.
        await dual.ConnectAsync();

        await dual.SendAsync(Envelope());

        Assert.Empty(lan.Sent);
        Assert.Single(cloud.Sent);
    }

    [Fact]
    public async Task RefusesToSendWhenNeitherIsUp()
    {
        var lan = new FakeTransport(TransportOrigin.Lan) { FailToConnect = true };
        var cloud = new FakeTransport(TransportOrigin.Cloud) { FailToConnect = true };
        await using var dual = new DualSyncTransport(lan, cloud);

        await Assert.ThrowsAsync<InvalidOperationException>(() => dual.ConnectAsync());
        await Assert.ThrowsAsync<InvalidOperationException>(() => dual.SendAsync(Envelope()));
    }

    [Fact]
    public async Task SurfacesAMessageThatArrivesOnBothChannelsOnce()
    {
        var lan = new FakeTransport(TransportOrigin.Lan);
        var cloud = new FakeTransport(TransportOrigin.Cloud);
        await using var dual = new DualSyncTransport(lan, cloud);

        var received = new List<SyncEnvelope>();
        dual.EnvelopeReceived += (_, e) => received.Add(e.Envelope);

        var envelope = Envelope();
        lan.Receive(envelope);
        cloud.Receive(envelope);

        Assert.Single(received);
    }

    [Fact]
    public async Task DoesNotSuppressAnInboundMessageThatReusesAnIdWeSent()
    {
        // The trap this class exists to avoid. The relay answers an
        // undeliverable message with an error envelope carrying *our* id; a
        // dedup cache that recorded outbound ids would then swallow a genuine
        // inbound message that happened to carry the same one.
        var lan = new FakeTransport(TransportOrigin.Lan);
        var cloud = new FakeTransport(TransportOrigin.Cloud);
        await using var dual = new DualSyncTransport(lan, cloud);
        await dual.ConnectAsync();

        var received = new List<SyncEnvelope>();
        dual.EnvelopeReceived += (_, e) => received.Add(e.Envelope);

        var id = Guid.NewGuid();
        await dual.SendAsync(Envelope(id));
        cloud.Receive(Envelope(id));

        Assert.Single(received);
        Assert.Equal(id, received[0].Id);
    }

    [Fact]
    public async Task ForgetsOldIdsRatherThanGrowingForever()
    {
        var lan = new FakeTransport(TransportOrigin.Lan);
        var cloud = new FakeTransport(TransportOrigin.Cloud);
        await using var dual = new DualSyncTransport(lan, cloud, dedupCapacity: 4);

        var received = new List<SyncEnvelope>();
        dual.EnvelopeReceived += (_, e) => received.Add(e.Envelope);

        var first = Envelope();
        lan.Receive(first);
        for (var i = 0; i < 4; i++)
        {
            lan.Receive(Envelope());
        }

        // Evicted, so it is surfaced again. That is the accepted cost of a
        // bounded cache: a duplicate long after the fact beats unbounded growth
        // in a process that runs for weeks.
        lan.Receive(first);

        Assert.Equal(6, received.Count);
    }

    [Fact]
    public async Task ReportsConnectedWhileEitherChannelIsUp()
    {
        var lan = new FakeTransport(TransportOrigin.Lan);
        var cloud = new FakeTransport(TransportOrigin.Cloud);
        await using var dual = new DualSyncTransport(lan, cloud);
        await dual.ConnectAsync();

        lan.SetState(TransportState.Disconnected);

        Assert.Equal(TransportState.Connected, dual.State);
        Assert.Equal(TransportOrigin.Cloud, dual.PreferredOrigin);

        cloud.SetState(TransportState.Disconnected);

        Assert.Equal(TransportState.Disconnected, dual.State);
        Assert.Null(dual.PreferredOrigin);
    }
}
