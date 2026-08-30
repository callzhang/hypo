using Hypo.Core.Discovery;
using Hypo.Core.Protocol;

namespace Hypo.Core.Transport;

/// <summary>
/// The local network as a single transport: it listens, it advertises, and it
/// dials the paired peers it discovers.
///
/// <para>Both halves are needed and neither is enough. A server alone receives
/// but can never originate -- the first Windows client shipped that way and its
/// LAN was silently one-directional. A client alone cannot be reached by a peer
/// that discovers <em>us</em> first, which is how a phone starts a sync.</para>
///
/// <para><b>Routing is per peer, not per transport.</b> Being "connected to the
/// LAN" says nothing about whether a particular peer is on it: a phone on
/// cellular and a laptop in the next room are both paired, and only one is
/// reachable. <see cref="SendAsync"/> therefore routes on the envelope's target
/// and throws <see cref="PeerUnreachableException"/> when it has no connection
/// for it, which is the signal <see cref="DualSyncTransport"/> uses to fall back
/// to the relay.</para>
/// </summary>
public sealed class LanSyncTransport : ISyncTransport
{
    private readonly IPeerDiscovery _discovery;
    private readonly LanWebSocketServer _server;
    private readonly string _localDeviceId;
    private readonly string _localDeviceName;
    private readonly Func<string, bool> _isPaired;

    private readonly Lock _gate = new();
    private readonly Dictionary<string, LanWebSocketClient> _outbound = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Peers a dial is already in flight for.
    ///
    /// <para>Checking _outbound alone is not enough: a peer's record is announced
    /// more than once -- mDNS re-announces, and a device that publishes under a
    /// changed instance name looks like a fresh discovery -- so two
    /// announcements can both pass the check before either connection lands. The
    /// second then replaces the first in the dictionary and its socket is leaked,
    /// still open and still delivering to an event handler nobody removes.</para>
    /// </summary>
    private readonly HashSet<string> _dialing = new(StringComparer.OrdinalIgnoreCase);

    private TransportState _state = TransportState.Disconnected;

    /// <param name="isPaired">
    /// Decides whether a discovered peer is one of ours. Dialling every device on
    /// the network would be both rude and useless -- without a key we could not
    /// read anything it sent.
    /// </param>
    public LanSyncTransport(
        IPeerDiscovery discovery,
        LanWebSocketServer server,
        string localDeviceId,
        string localDeviceName,
        Func<string, bool> isPaired)
    {
        ArgumentNullException.ThrowIfNull(discovery);
        ArgumentNullException.ThrowIfNull(server);
        ArgumentException.ThrowIfNullOrWhiteSpace(localDeviceId);
        ArgumentNullException.ThrowIfNull(isPaired);

        _discovery = discovery;
        _server = server;
        _localDeviceId = localDeviceId.ToLowerInvariant();
        _localDeviceName = localDeviceName;
        _isPaired = isPaired;

        _server.EnvelopeReceived += (_, e) => EnvelopeReceived?.Invoke(this, e);
        _discovery.PeerDiscovered += OnPeerDiscovered;
    }

    public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;
    public event EventHandler<TransportStateChangedEventArgs>? StateChanged;

    /// <summary>Raised when a paired peer becomes dialable, for callers that log it.</summary>
    public event EventHandler<DiscoveredPeer>? PeerConnected;

    /// <summary>
    /// Connected once at least one paired peer is dialable.
    ///
    /// <para>Not "the server is listening": the server being up means we can be
    /// reached, which says nothing about whether we can reach anyone. Reporting
    /// Connected on that basis would make the dual transport prefer a LAN with
    /// nobody on it.</para>
    /// </summary>
    public TransportState State => _state;

    /// <summary>Device ids currently dialable over the LAN.</summary>
    public IReadOnlyCollection<string> ConnectedPeers
    {
        get { lock (_gate) { return _outbound.Keys.ToArray(); } }
    }

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        await _server.StartAsync(ct).ConfigureAwait(false);

        await _discovery.AdvertiseAsync(
            _localDeviceName,
            _server.BoundPort,
            new Dictionary<string, string>
            {
                ["device_id"] = _localDeviceId,
                ["version"] = "1.0.0-windows",
            },
            ct).ConfigureAwait(false);

        await _discovery.StartBrowsingAsync(ct).ConfigureAwait(false);

        // Deliberately not waiting for a peer. Discovery is asynchronous and may
        // never find anyone; a client that refused to start until the LAN had
        // someone on it would fail to start on a network with only a relay.
        SetState(TransportState.Disconnected, null);
    }

    public async Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(envelope);

        var target = envelope.Payload.Target
                     ?? throw new PeerUnreachableException("<no target>");

        LanWebSocketClient? client;
        lock (_gate)
        {
            _outbound.TryGetValue(target, out client);
        }

        if (client is null || client.State != TransportState.Connected)
        {
            throw new PeerUnreachableException(target);
        }

        await client.SendAsync(envelope, ct).ConfigureAwait(false);
    }

    public async Task DisconnectAsync(CancellationToken ct = default)
    {
        LanWebSocketClient[] clients;
        lock (_gate)
        {
            clients = _outbound.Values.ToArray();
            _outbound.Clear();
            _dialing.Clear();
        }

        foreach (var client in clients)
        {
            await client.DisconnectAsync(ct).ConfigureAwait(false);
        }

        SetState(TransportState.Disconnected, null);
    }

    private void OnPeerDiscovered(object? sender, DiscoveredPeer peer)
    {
        if (peer.DeviceId is null
            || string.Equals(peer.DeviceId, _localDeviceId, StringComparison.OrdinalIgnoreCase)
            || !_isPaired(peer.DeviceId))
        {
            return;
        }

        lock (_gate)
        {
            if (_outbound.ContainsKey(peer.DeviceId) || !_dialing.Add(peer.DeviceId))
            {
                return;
            }
        }

        _ = Task.Run(() => DialAsync(peer));
    }

    private async Task DialAsync(DiscoveredPeer peer)
    {
        var client = new LanWebSocketClient(peer, _localDeviceId);

        try
        {
            await client.ConnectAsync().ConfigureAwait(false);
        }
        catch (Exception)
        {
            // A peer that advertised and will not answer is ordinary: the record
            // outlives the process that published it. The relay covers it.
            await client.DisposeAsync().ConfigureAwait(false);

            lock (_gate)
            {
                _dialing.Remove(peer.DeviceId!);
            }

            return;
        }

        client.EnvelopeReceived += (_, e) => EnvelopeReceived?.Invoke(this, e);
        client.StateChanged += (_, e) =>
        {
            if (e.State is TransportState.Disconnected or TransportState.Faulted)
            {
                Forget(peer.DeviceId!);
            }
        };

        bool first;
        lock (_gate)
        {
            _dialing.Remove(peer.DeviceId!);
            first = _outbound.TryAdd(peer.DeviceId!, client);
        }

        if (!first)
        {
            // Lost a race we thought we had won; keep the connection that landed
            // first rather than leaving two sockets to the same peer.
            await client.DisposeAsync().ConfigureAwait(false);
            return;
        }

        SetState(TransportState.Connected, null);
        PeerConnected?.Invoke(this, peer);
    }

    private void Forget(string deviceId)
    {
        lock (_gate)
        {
            _outbound.Remove(deviceId);
        }

        // Still Connected while any other peer remains: one phone leaving the
        // network must not push the rest of the sync onto the relay.
        SetState(ConnectedPeers.Count > 0 ? TransportState.Connected : TransportState.Disconnected, null);
    }

    private void SetState(TransportState state, Exception? error)
    {
        if (_state == state)
        {
            return;
        }

        _state = state;
        StateChanged?.Invoke(this, new TransportStateChangedEventArgs(state, error));
    }

    public async ValueTask DisposeAsync()
    {
        _discovery.PeerDiscovered -= OnPeerDiscovered;

        await DisconnectAsync().ConfigureAwait(false);
        await _server.DisposeAsync().ConfigureAwait(false);
        await _discovery.DisposeAsync().ConfigureAwait(false);
    }
}
