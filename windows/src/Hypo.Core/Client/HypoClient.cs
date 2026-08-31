using Hypo.Core.Abstractions;
using Hypo.Core.Discovery;
using Hypo.Core.History;
using Hypo.Core.Relay;
using Hypo.Core.Sync;
using Hypo.Core.Transport;

namespace Hypo.Core.Client;

/// <summary>
/// Everything a client is, assembled: discovery, both transports, the history
/// and the coordinator that joins them to a clipboard.
///
/// <para>This exists so there is exactly one wiring. The Windows application and
/// the test harness differ only in which <see cref="IClipboard"/> they hand it,
/// which means the composition can be exercised on a machine that is not
/// Windows -- and given that no Windows machine is available here, a composition
/// only the shipping binary used would be the one part of the client nobody ever
/// ran.</para>
/// </summary>
public sealed class HypoClient : IAsyncDisposable
{
    private readonly LanSyncTransport _lan;
    private readonly CloudWebSocketClient _cloud;
    private readonly DualSyncTransport _transport;
    private readonly ClipboardHistoryStore _history;
    private readonly bool _ownsHistory;

    private HypoClient(
        LanSyncTransport lan,
        CloudWebSocketClient cloud,
        DualSyncTransport transport,
        SyncCoordinator coordinator,
        ClipboardHistoryStore history,
        bool ownsHistory)
    {
        _lan = lan;
        _cloud = cloud;
        _transport = transport;
        _history = history;
        _ownsHistory = ownsHistory;

        Coordinator = coordinator;
    }

    public SyncCoordinator Coordinator { get; }

    public ClipboardHistoryStore History => _history;

    /// <summary>Device ids reachable on the local network right now.</summary>
    public IReadOnlyCollection<string> LanPeers => _lan.ConnectedPeers;

    public TransportState State => _transport.State;

    public event EventHandler<DiscoveredPeer>? LanPeerConnected
    {
        add => _lan.PeerConnected += value;
        remove => _lan.PeerConnected -= value;
    }

    public event EventHandler<RelayErrorReceivedEventArgs>? RelayError
    {
        add => _cloud.RelayErrorReceived += value;
        remove => _cloud.RelayErrorReceived -= value;
    }

    public static HypoClient Create(
        IClipboard clipboard,
        ISecretStore store,
        ClipboardHistoryStore history,
        string deviceId,
        string deviceName,
        RelayOptions relay,
        IPeerDiscovery? discovery = null,
        int lanPort = LanWebSocketServer.DefaultPort,
        bool ownsHistory = false,
        bool lanEnabled = true,
        bool cloudEnabled = true)
    {
        ArgumentNullException.ThrowIfNull(clipboard);
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(history);
        ArgumentNullException.ThrowIfNull(relay);

        var peers = PairedPeers(store);

        var lan = new LanSyncTransport(
            discovery ?? new MdnsPeerDiscovery(),
            new LanWebSocketServer(lanPort),
            deviceId,
            deviceName,
            // Read through the store each time rather than a snapshot: pairing
            // while the client runs must make that peer dialable without a restart.
            peerId => store.Read(peerId) is not null);

        var cloud = new CloudWebSocketClient(relay);
        var transport = new DualSyncTransport(lan, cloud);

        var coordinator = new SyncCoordinator(
            clipboard, transport, store, history, deviceId, deviceName);

        foreach (var peer in peers)
        {
            coordinator.Peers.Add(peer);
        }

        return new HypoClient(lan, cloud, transport, coordinator, history, ownsHistory)
        {
            LanEnabled = lanEnabled,
            CloudEnabled = cloudEnabled,
        };
    }

    /// <summary>
    /// The peers this client syncs with: every GUID-shaped key in the store.
    ///
    /// <para>The store also holds this device's own id and its signing key, which
    /// are not peers. Filtering on shape rather than maintaining a second list
    /// keeps pairing the single source of truth.</para>
    /// </summary>
    public static IReadOnlyList<string> PairedPeers(ISecretStore store)
    {
        ArgumentNullException.ThrowIfNull(store);

        return store.Keys().Where(key => Guid.TryParse(key, out _)).ToArray();
    }

    /// <summary>
    /// Connects both transports. Succeeds if either works: a LAN with nobody on
    /// it and an unreachable relay are different failures, and only both at once
    /// means the client cannot do its job.
    /// </summary>
    /// <summary>
    /// Whether the LAN transport is brought up at all.
    ///
    /// <para>A transport that is never connected is skipped by everything
    /// downstream: sending checks each channel's state, so turning one off needs
    /// no special case anywhere else. Turning both off leaves an application
    /// that keeps a history and syncs with nobody, which is a choice someone is
    /// entitled to make.</para>
    /// </summary>
    public bool LanEnabled { get; init; } = true;

    public bool CloudEnabled { get; init; } = true;

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (LanEnabled)
        {
            await _lan.ConnectAsync(ct).ConfigureAwait(false);
        }

        if (!CloudEnabled)
        {
            return;
        }

        try
        {
            await _cloud.ConnectAsync(ct).ConfigureAwait(false);
        }
        catch (Exception) when (_lan.State == TransportState.Connected)
        {
            // A working LAN is enough to be useful; the relay reconnects on its own.
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _transport.DisposeAsync().ConfigureAwait(false);

        if (_ownsHistory)
        {
            _history.Dispose();
        }
    }
}
