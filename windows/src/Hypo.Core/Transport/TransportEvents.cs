using Hypo.Core.Protocol;

namespace Hypo.Core.Transport;

/// <summary>Which channel a message arrived on. Matches TransportOrigin on macOS.</summary>
public enum TransportOrigin
{
    Lan,
    Cloud,
}

public enum TransportState
{
    Disconnected,
    Connecting,
    Connected,
    Faulted,
}

public sealed class EnvelopeReceivedEventArgs(
    SyncEnvelope envelope,
    string peerDeviceId,
    TransportOrigin origin) : EventArgs
{
    public SyncEnvelope Envelope { get; } = envelope;

    /// <summary>
    /// The peer this arrived from, as the transport understands it — from the
    /// handshake, not from the envelope body. The two can disagree, and a peer
    /// claiming to be someone else in the body is exactly what the envelope's
    /// authenticated associated data exists to catch.
    /// </summary>
    public string PeerDeviceId { get; } = peerDeviceId;

    public TransportOrigin Origin { get; } = origin;
}

public sealed class TransportStateChangedEventArgs(TransportState state, Exception? error) : EventArgs
{
    public TransportState State { get; } = state;

    public Exception? Error { get; } = error;
}

/// <summary>
/// A pairing message, which travels as an unframed WebSocket text frame rather
/// than the length-prefixed binary frames clipboard traffic uses. See the design
/// spec section 3.2.1 — this asymmetry is what the shipping clients do, and it
/// is not documented in the protocol spec.
/// </summary>
public sealed class PairingMessageReceivedEventArgs(string json, string connectionId) : EventArgs
{
    /// <summary>The raw JSON body. Callers parse it as a challenge or an ack.</summary>
    public string Json { get; } = json;

    /// <summary>Identifies the connection, so a server can reply on the same one.</summary>
    public string ConnectionId { get; } = connectionId;
}
