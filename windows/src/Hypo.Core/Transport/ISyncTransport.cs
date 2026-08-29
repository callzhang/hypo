using Hypo.Core.Protocol;

namespace Hypo.Core.Transport;

/// <summary>
/// One channel over which envelopes travel. Plan 2 implemented the LAN client
/// and server; Plan 4 adds the cloud relay and <see cref="DualSyncTransport"/>,
/// which picks between them.
///
/// This comment used to say the dual transport "fans one message across both".
/// It does not: that would deliver the same clipboard item to the peer twice
/// and leave the peer to sort it out. It prefers the LAN and falls back to the
/// relay.
/// </summary>
public interface ISyncTransport : IAsyncDisposable
{
    event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;

    event EventHandler<TransportStateChangedEventArgs>? StateChanged;

    TransportState State { get; }

    Task ConnectAsync(CancellationToken ct = default);

    /// <summary>
    /// Sends one envelope. Callers fanning a message across several transports
    /// must give each a separately generated nonce: reusing one under a single
    /// key is catastrophic. See CryptoService.Encrypt's remarks.
    /// </summary>
    Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default);

    Task DisconnectAsync(CancellationToken ct = default);
}
