namespace Hypo.Core.Discovery;

/// <summary>Publishes this device and watches for peers on the local network.</summary>
public interface IPeerDiscovery : IAsyncDisposable
{
    /// <summary>Raised when a peer is first seen or its record changes.</summary>
    event EventHandler<DiscoveredPeer>? PeerDiscovered;

    // Peer loss is deliberately not reported yet. Makaretu surfaces goodbye
    // packets inconsistently, and a peer that stopped answering is
    // indistinguishable from one on a flaky network, so eviction needs a
    // last-seen timestamp rather than an event. Plan 3 adds it, matching what
    // the macOS client does.

    /// <summary>
    /// Advertises this device. The port must be the port actually bound, not the
    /// configured one — the server falls back to an ephemeral port when 7010 is
    /// taken, and a peer that dials the wrong port simply never connects.
    /// </summary>
    Task AdvertiseAsync(string deviceName, int port, IReadOnlyDictionary<string, string> txt, CancellationToken ct = default);

    Task StartBrowsingAsync(CancellationToken ct = default);

    /// <summary>
    /// Re-queries the network.
    ///
    /// <para>Browsing alone is not enough over time. A peer announces when it
    /// starts, and a client that only listens for announcements misses anyone who
    /// was already there, and never hears again from one whose connection dropped
    /// without its record changing. Asking again is how a dropped LAN link
    /// recovers without waiting for the peer to restart.</para>
    /// </summary>
    void Refresh();

    IReadOnlyCollection<DiscoveredPeer> KnownPeers { get; }
}
