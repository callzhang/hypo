using Hypo.Core.Protocol;

namespace Hypo.Core.Transport;

/// <summary>
/// One channel over which envelopes travel. Plan 2 implements the LAN client and
/// server; Plan 3 adds the cloud relay and the dual-send transport that fans one
/// message across both.
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
