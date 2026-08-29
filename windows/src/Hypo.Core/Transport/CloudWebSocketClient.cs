using System.Net.WebSockets;
using System.Text.Json;
using Hypo.Core.Protocol;
using Hypo.Core.Relay;

namespace Hypo.Core.Transport;

/// <summary>
/// Connection to the relay at <see cref="RelayOptions.Endpoint"/>, for peers
/// that are not on the same network.
///
/// <para>Framing is byte-identical to the LAN's: a binary frame carrying a
/// 4-byte big-endian length and then the envelope JSON, which the relay
/// forwards untouched after reading just enough to route. What differs is the
/// upgrade (three headers, and the auth token signs the *lowercased* device
/// id), that nothing arrives on connect, and that the relay itself can speak —
/// an undeliverable message comes back as a <c>type: "error"</c> envelope.</para>
///
/// <para>There is no pairing channel here. Pairing over the relay uses the
/// REST endpoints under <c>/api/pairing</c>, not this socket, so unlike the LAN
/// client every binary frame is clipboard traffic and text frames are unexpected.</para>
/// </summary>
public sealed class CloudWebSocketClient : ISyncTransport, IDisposable
{
    private readonly RelayOptions _options;
    private readonly TransportFrameCodec _codec = new();
    private readonly FrameReader _reader = new();

    private ClientWebSocket? _socket;
    private CancellationTokenSource? _pump;
    private TransportState _state = TransportState.Disconnected;

    public CloudWebSocketClient(RelayOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _options = options;
    }

    public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;
    public event EventHandler<TransportStateChangedEventArgs>? StateChanged;

    /// <summary>Raised when the relay reports it could not deliver something.</summary>
    public event EventHandler<RelayErrorReceivedEventArgs>? RelayErrorReceived;

    public TransportState State => _state;

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        if (_state is TransportState.Connected or TransportState.Connecting)
        {
            return;
        }

        SetState(TransportState.Connecting, null);
        _reader.Reset();

        var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("X-Device-Id", _options.DeviceId);
        socket.Options.SetRequestHeader("X-Device-Platform", _options.Platform);
        socket.Options.SetRequestHeader("X-Auth-Token", _options.AuthToken);

        try
        {
            await socket.ConnectAsync(_options.Endpoint, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            socket.Dispose();
            SetState(TransportState.Faulted, ex);
            throw;
        }

        _socket = socket;
        _pump = CancellationTokenSource.CreateLinkedTokenSource(ct);

        // The relay sends nothing on connect -- no welcome, no ack, no session
        // id. Waiting for one waits forever, so the socket being open is the
        // whole of the handshake.
        SetState(TransportState.Connected, null);
        _ = Task.Run(() => PumpAsync(_pump.Token), CancellationToken.None);
    }

    public async Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(envelope);

        var socket = _socket;
        if (socket is null || socket.State != WebSocketState.Open)
        {
            throw new InvalidOperationException("The relay transport is not connected.");
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
                // Best effort; the relay may have gone first.
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

                if (result.MessageType == WebSocketMessageType.Text)
                {
                    // No text traffic is expected on this socket. Ignore rather
                    // than fault: the relay is shared infrastructure and may
                    // grow message kinds before this client learns about them.
                    continue;
                }

                // A WebSocket message boundary is not a frame boundary.
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

    /// <summary>
    /// Routes on the envelope's <c>type</c> before any strict decode, because
    /// an error envelope's payload has neither ciphertext nor an encryption
    /// block and would throw on the way in.
    /// </summary>
    private void Dispatch(byte[] body)
    {
        MessageType type;
        try
        {
            using var document = JsonDocument.Parse(body);
            type = document.RootElement.TryGetProperty("type", out var element)
                   && element.ValueKind == JsonValueKind.String
                ? element.GetString() switch
                {
                    "clipboard" => MessageType.Clipboard,
                    "error" => MessageType.Error,
                    "control" => MessageType.Control,
                    _ => (MessageType)(-1),
                }
                : (MessageType)(-1);
        }
        catch (JsonException)
        {
            // Malformed protocol data is not a reason to tear the connection
            // down; drop the message and keep reading.
            return;
        }

        switch (type)
        {
            case MessageType.Error:
                DispatchError(body);
                return;

            case MessageType.Clipboard:
                DispatchEnvelope(body);
                return;

            default:
                // Control messages and anything newer than this client.
                return;
        }
    }

    private void DispatchError(byte[] body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var payload = document.RootElement.GetProperty("payload");

            RelayErrorReceived?.Invoke(this, new RelayErrorReceivedEventArgs(new RelayError
            {
                Code = payload.TryGetProperty("code", out var code) ? code.GetString() ?? "unknown" : "unknown",
                Message = payload.TryGetProperty("message", out var m) ? m.GetString() : null,
                TargetDeviceId = payload.TryGetProperty("target_device_id", out var t) ? t.GetString() : null,
                OriginalMessageId = payload.TryGetProperty("original_message_id", out var o)
                                    && Guid.TryParse(o.GetString(), out var id) ? id : null,
                ConnectedDevices = payload.TryGetProperty("connected_devices", out var devices)
                                   && devices.ValueKind == JsonValueKind.Array
                    ? devices.EnumerateArray().Select(d => d.GetString() ?? string.Empty).ToArray()
                    : [],
            }));
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            // An error we cannot parse is still not worth dropping the socket for.
        }
    }

    private void DispatchEnvelope(byte[] body)
    {
        SyncEnvelope envelope;
        try
        {
            var framed = new byte[4 + body.Length];
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(framed, (uint)body.Length);
            body.CopyTo(framed.AsSpan(4));
            envelope = _codec.Decode(framed);
        }
        catch (Exception ex) when (ex is TransportFrameException or JsonException)
        {
            return;
        }

        // Unlike the LAN, there is no handshake to learn the peer from, so this
        // comes from the body and is unauthenticated until decryption checks it
        // against the associated data -- which is exactly the check that makes
        // trusting it safe.
        EnvelopeReceived?.Invoke(
            this,
            new EnvelopeReceivedEventArgs(envelope, envelope.Payload.DeviceId, TransportOrigin.Cloud));
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
