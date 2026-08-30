namespace Hypo.Core.Transport;

/// <summary>
/// A transport was asked to reach a peer it has no route to.
///
/// <para>Deliberately its own type rather than a generic failure:
/// <see cref="DualSyncTransport"/> falls back to the relay when the LAN cannot
/// reach a peer, and falling back on <em>any</em> exception would hide real
/// send errors behind a second attempt that quietly succeeds.</para>
/// </summary>
public sealed class PeerUnreachableException(string peerDeviceId)
    : Exception($"No route to {peerDeviceId} on this transport.")
{
    public string PeerDeviceId { get; } = peerDeviceId;
}
