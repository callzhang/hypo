using Hypo.Core.Protocol;

namespace Hypo.Core.Transport;

/// <summary>
/// Sends over the LAN when the LAN is available and over the relay otherwise,
/// and surfaces a message that arrives on both exactly once.
///
/// <para><b>Preference, not fan-out.</b> An earlier comment on
/// <see cref="ISyncTransport"/> described this as fanning one message across
/// both channels. That would put two copies of the same clipboard item on the
/// peer, and leaves the peer to sort it out. LAN is preferred because it is
/// faster, it does not leave the building, and it still works when the relay is
/// down; the relay is what you use when the LAN cannot reach.</para>
///
/// <para><b>Dedup is inbound only.</b> Messages we send are deliberately not
/// recorded. The relay answers an undeliverable message with an error envelope
/// that reuses <em>our</em> message id, so a cache holding outbound ids would
/// then suppress a genuine inbound message that happened to carry it. Errors
/// never reach here in the first place -- <see cref="CloudWebSocketClient"/>
/// routes them to its own event -- and this class stays out of the way by not
/// recording what it sends.</para>
/// </summary>
public sealed class DualSyncTransport : ISyncTransport
{
    private readonly ISyncTransport _lan;
    private readonly ISyncTransport _cloud;
    private readonly int _dedupCapacity;

    private readonly Lock _gate = new();
    private readonly HashSet<Guid> _seen = [];
    private readonly Queue<Guid> _order = new();

    public DualSyncTransport(ISyncTransport lan, ISyncTransport cloud, int dedupCapacity = 512)
    {
        ArgumentNullException.ThrowIfNull(lan);
        ArgumentNullException.ThrowIfNull(cloud);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(dedupCapacity);

        _lan = lan;
        _cloud = cloud;
        _dedupCapacity = dedupCapacity;

        _lan.EnvelopeReceived += OnEnvelopeReceived;
        _cloud.EnvelopeReceived += OnEnvelopeReceived;
        _lan.StateChanged += OnStateChanged;
        _cloud.StateChanged += OnStateChanged;
    }

    public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;
    public event EventHandler<TransportStateChangedEventArgs>? StateChanged;

    /// <summary>Connected when either channel is, because either can carry a message.</summary>
    public TransportState State =>
        _lan.State == TransportState.Connected || _cloud.State == TransportState.Connected
            ? TransportState.Connected
            : _lan.State == TransportState.Connecting || _cloud.State == TransportState.Connecting
                ? TransportState.Connecting
                : _lan.State == TransportState.Faulted && _cloud.State == TransportState.Faulted
                    ? TransportState.Faulted
                    : TransportState.Disconnected;

    /// <summary>
    /// Which channel a send would prefer, ignoring whether a particular peer is
    /// reachable on it. <see cref="SendAsync"/> is the authority; this is for
    /// callers that want to show a status.
    /// </summary>
    public TransportOrigin? PreferredOrigin =>
        _lan.State == TransportState.Connected ? TransportOrigin.Lan
        : _cloud.State == TransportState.Connected ? TransportOrigin.Cloud
        : null;

    /// <summary>
    /// Connects both. A channel that fails does not stop the other: having one
    /// is the whole point, and refusing to start because the relay is
    /// unreachable would make a working LAN useless.
    /// </summary>
    public async Task ConnectAsync(CancellationToken ct = default)
    {
        // Deferred, not eagerly evaluated: a transport that throws
        // synchronously -- argument validation, a socket that fails before its
        // first await -- would otherwise escape past the isolation below and
        // take the working channel down with it.
        await Task.WhenAll(
            Attempt(() => _lan.ConnectAsync(ct)),
            Attempt(() => _cloud.ConnectAsync(ct))).ConfigureAwait(false);

        if (State is not TransportState.Connected)
        {
            throw new InvalidOperationException("Neither the LAN nor the relay could be reached.");
        }

        static async Task Attempt(Func<Task> connect)
        {
            try
            {
                await connect().ConfigureAwait(false);
            }
            catch
            {
                // Recorded in the channel's own state; the other may still work.
            }
        }
    }

    /// <summary>
    /// Sends over the LAN when it can reach this envelope's peer, and over the
    /// relay otherwise.
    ///
    /// <para>The fallback is per peer rather than per transport, because "the LAN
    /// is up" says nothing about whether a given device is on it -- a phone on
    /// cellular and a laptop in the next room are both paired, and only one is
    /// reachable. The LAN reports that with
    /// <see cref="PeerUnreachableException"/>, and only that: falling back on any
    /// failure would hide a real send error behind a second attempt that quietly
    /// succeeds.</para>
    /// </summary>
    public async Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(envelope);

        if (_lan.State == TransportState.Connected)
        {
            try
            {
                await _lan.SendAsync(envelope, ct).ConfigureAwait(false);
                return;
            }
            catch (PeerUnreachableException)
            {
                // This peer is not on the LAN, though others may be.
            }
        }

        if (_cloud.State == TransportState.Connected)
        {
            await _cloud.SendAsync(envelope, ct).ConfigureAwait(false);
            return;
        }

        throw new InvalidOperationException(
            "Neither the LAN nor the relay can reach " +
            $"{envelope.Payload.Target ?? "the peer"}.");
    }

    public async Task DisconnectAsync(CancellationToken ct = default)
    {
        await _lan.DisconnectAsync(ct).ConfigureAwait(false);
        await _cloud.DisconnectAsync(ct).ConfigureAwait(false);
    }

    private void OnEnvelopeReceived(object? sender, EnvelopeReceivedEventArgs e)
    {
        lock (_gate)
        {
            if (!_seen.Add(e.Envelope.Id))
            {
                return;
            }

            _order.Enqueue(e.Envelope.Id);
            while (_order.Count > _dedupCapacity)
            {
                _seen.Remove(_order.Dequeue());
            }
        }

        EnvelopeReceived?.Invoke(this, e);
    }

    private void OnStateChanged(object? sender, TransportStateChangedEventArgs e) =>
        StateChanged?.Invoke(this, new TransportStateChangedEventArgs(State, e.Error));

    public async ValueTask DisposeAsync()
    {
        _lan.EnvelopeReceived -= OnEnvelopeReceived;
        _cloud.EnvelopeReceived -= OnEnvelopeReceived;
        _lan.StateChanged -= OnStateChanged;
        _cloud.StateChanged -= OnStateChanged;

        await _lan.DisposeAsync().ConfigureAwait(false);
        await _cloud.DisposeAsync().ConfigureAwait(false);
    }
}
