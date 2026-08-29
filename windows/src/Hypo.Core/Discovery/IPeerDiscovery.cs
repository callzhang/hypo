namespace Hypo.Core.Discovery;

/// <summary>Publishes this device and watches for peers on the local network.</summary>
public interface IPeerDiscovery : IAsyncDisposable
{
    /// <summary>Raised when a peer is first seen or its record changes.</summary>
    event EventHandler<DiscoveredPeer>? PeerDiscovered;

    /// <summary>Raised when a peer withdraws its advertisement.</summary>
    event EventHandler<string>? PeerLost;

    /// <summary>
    /// Advertises this device. The port must be the port actually bound, not the
    /// configured one — the server falls back to an ephemeral port when 7010 is
    /// taken, and a peer that dials the wrong port simply never connects.
    /// </summary>
    Task AdvertiseAsync(string deviceName, int port, IReadOnlyDictionary<string, string> txt, CancellationToken ct = default);

    Task StartBrowsingAsync(CancellationToken ct = default);

    IReadOnlyCollection<DiscoveredPeer> KnownPeers { get; }
}
