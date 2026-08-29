using System.Net.WebSockets;
using Hypo.Core.Discovery;
using Hypo.Core.Protocol;

namespace Hypo.Core.Transport;

/// <summary>
/// Outbound LAN connection to a discovered peer. Plain ws:// by design: the
/// TXT record's "protocols=ws+tls" is advertised by both shipping clients and
/// implemented by neither, and payload encryption is the security boundary.
/// </summary>
public sealed class LanWebSocketClient : ISyncTransport, IDisposable
{
    private readonly DiscoveredPeer _peer;
    private readonly string _localDeviceId;
    private readonly TransportFrameCodec _codec = new();
    private readonly FrameReader _reader = new();

    private ClientWebSocket? _socket;
    private CancellationTokenSource? _pump;
    private TransportState _state = TransportState.Disconnected;

    public LanWebSocketClient(DiscoveredPeer peer, string localDeviceId)
    {
        ArgumentNullException.ThrowIfNull(peer);
        ArgumentException.ThrowIfNullOrWhiteSpace(localDeviceId);

        _peer = peer;
        _localDeviceId = localDeviceId.ToLowerInvariant();
    }

    public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;
    public event EventHandler<TransportStateChangedEventArgs>? StateChanged;

    public TransportState State => _state;

    public string PeerDeviceId => _peer.DeviceId ?? _peer.InstanceName;

    /// <summary>
    /// The macOS server reads the device id from an X-Device-Id header or a
    /// device_id query parameter and accepts either, so both are sent.
    /// </summary>
    public static Uri BuildUri(DiscoveredPeer peer, string localDeviceId)
    {
        ArgumentNullException.ThrowIfNull(peer);
        ArgumentException.ThrowIfNullOrWhiteSpace(localDeviceId);

        return new Uri($"ws://{peer.Address}:{peer.Port}/?device_id={localDeviceId.ToLowerInvariant()}");
    }

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        if (_state is TransportState.Connected or TransportState.Connecting)
        {
            return;
        }

        SetState(TransportState.Connecting, null);
        _reader.Reset();

        var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("X-Device-Id", _localDeviceId);

        try
        {
            await socket.ConnectAsync(BuildUri(_peer, _localDeviceId), ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            socket.Dispose();
            SetState(TransportState.Faulted, ex);
            throw;
        }

        _socket = socket;
        _pump = CancellationTokenSource.CreateLinkedTokenSource(ct);
        SetState(TransportState.Connected, null);
        _ = Task.Run(() => PumpAsync(_pump.Token), CancellationToken.None);
    }

    public async Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(envelope);

        var socket = _socket;
        if (socket is null || socket.State != WebSocketState.Open)
        {
            throw new InvalidOperationException("The transport is not connected.");
        }

        var frame = _codec.Encode(envelope);
        await socket.SendAsync(frame, WebSocketMessageType.Binary, true, ct).ConfigureAwait(false);
    }

    public async Task DisconnectAsync(CancellationToken ct = default)
    {
        if (_pump is not null)
        {
            await _pump.CancelAsync().ConfigureAwait(false);
        }

        var socket = _socket;
        if (socket is { State: WebSocketState.Open })
        {
            try
            {
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", ct).ConfigureAwait(false);
            }
            catch (WebSocketException)
            {
                // The peer may have gone already. Closing is best effort.
            }
        }

        SetState(TransportState.Disconnected, null);
    }

    private async Task PumpAsync(CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        var socket = _socket!;

        try
        {
            while (!ct.IsCancellationRequested && socket.State == WebSocketState.Open)
            {
                var result = await socket.ReceiveAsync(buffer, ct).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }

                // A WebSocket message boundary is not a frame boundary: FrameReader
                // owns reassembly across both partial and coalesced reads.
                foreach (var body in _reader.Append(buffer.AsSpan(0, result.Count)))
                {
                    Dispatch(body);
                }
            }

            SetState(TransportState.Disconnected, null);
        }
        catch (OperationCanceledException)
        {
            SetState(TransportState.Disconnected, null);
        }
        catch (Exception ex)
        {
            SetState(TransportState.Faulted, ex);
        }
    }

    private void Dispatch(byte[] body)
    {
        SyncEnvelope envelope;
        try
        {
            // Decode expects the length prefix, which FrameReader has stripped.
            var framed = new byte[4 + body.Length];
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(framed, (uint)body.Length);
            body.CopyTo(framed.AsSpan(4));
            envelope = _codec.Decode(framed);
        }
        catch (Exception ex) when (ex is TransportFrameException or System.Text.Json.JsonException)
        {
            // A peer sending malformed protocol data is not a reason to tear the
            // connection down; drop the message and keep reading.
            return;
        }

        EnvelopeReceived?.Invoke(this, new EnvelopeReceivedEventArgs(envelope, PeerDeviceId, TransportOrigin.Lan));
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

    public void Dispose()
    {
        _pump?.Dispose();
        _socket?.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        await DisconnectAsync().ConfigureAwait(false);
        Dispose();
    }
}
