using System.Net;
using System.Net.WebSockets;
using Hypo.Core.Protocol;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Hypo.Core.Transport;

/// <summary>
/// Accepts inbound LAN connections from peers. Plain ws://, matching the
/// shipping clients; payload encryption is the security boundary.
/// </summary>
public sealed class LanWebSocketServer : IAsyncDisposable
{
    /// <summary>The port both shipping clients advertise and dial.</summary>
    public const int DefaultPort = 7010;

    private readonly int _preferredPort;
    private readonly TransportFrameCodec _codec = new();

    private WebApplication? _app;

    public LanWebSocketServer(int port = DefaultPort)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(port);

        _preferredPort = port;
    }

    public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;

    /// <summary>
    /// The port in use, or 0 before starting. Discovery must advertise this
    /// rather than the preferred port: when 7010 is taken the server falls back
    /// to an ephemeral one, and a peer dialling the wrong port never connects.
    /// </summary>
    public int BoundPort { get; private set; }

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_app is not null)
        {
            return;
        }

        _app = await BuildAsync(_preferredPort, ct).ConfigureAwait(false)
               ?? await BuildAsync(0, ct).ConfigureAwait(false)
               ?? throw new IOException("Could not bind a LAN listener on any port.");

        BoundPort = ReadBoundPort(_app);
    }

    private async Task<WebApplication?> BuildAsync(int port, CancellationToken ct)
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();

        // Any IP, not localhost: peers connect from across the network. And
        // dynamic binding is only supported on an explicit address —
        // ListenLocalhost(0) throws "Dynamic port binding is not supported".
        builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Any, port));

        var app = builder.Build();
        app.UseWebSockets();
        app.Use(HandleAsync);

        try
        {
            await app.StartAsync(ct).ConfigureAwait(false);
            return app;
        }
        catch (IOException)
        {
            // Port in use. The caller retries on 0.
            await app.DisposeAsync().ConfigureAwait(false);
            return null;
        }
    }

    private async Task HandleAsync(HttpContext context, RequestDelegate next)
    {
        if (!context.WebSockets.IsWebSocketRequest)
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }

        // Both shipping clients are accommodated: macOS sends a header, Android
        // is documented in the macOS server as often using the query string.
        var peerDeviceId = context.Request.Headers["X-Device-Id"].ToString();
        if (string.IsNullOrWhiteSpace(peerDeviceId))
        {
            peerDeviceId = context.Request.Query["device_id"].ToString();
        }

        using var socket = await context.WebSockets.AcceptWebSocketAsync().ConfigureAwait(false);
        await PumpAsync(socket, peerDeviceId.ToLowerInvariant(), context.RequestAborted).ConfigureAwait(false);
    }

    private async Task PumpAsync(WebSocket socket, string peerDeviceId, CancellationToken ct)
    {
        var reader = new FrameReader();
        var buffer = new byte[16 * 1024];

        try
        {
            while (socket.State == WebSocketState.Open && !ct.IsCancellationRequested)
            {
                var result = await socket.ReceiveAsync(buffer, ct).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }

                foreach (var body in reader.Append(buffer.AsSpan(0, result.Count)))
                {
                    Dispatch(body, peerDeviceId);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Shutting down.
        }
        catch (WebSocketException)
        {
            // The peer vanished. Nothing to recover.
        }
        catch (TransportFrameException)
        {
            // An oversized length prefix means the stream position is no longer
            // trustworthy, so this connection cannot continue.
        }
    }

    private void Dispatch(byte[] body, string peerDeviceId)
    {
        SyncEnvelope envelope;
        try
        {
            var framed = new byte[4 + body.Length];
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(framed, (uint)body.Length);
            body.CopyTo(framed.AsSpan(4));
            envelope = _codec.Decode(framed);
        }
        catch (Exception ex) when (ex is TransportFrameException or System.Text.Json.JsonException)
        {
            return;
        }

        EnvelopeReceived?.Invoke(this, new EnvelopeReceivedEventArgs(envelope, peerDeviceId, TransportOrigin.Lan));
    }

    private static int ReadBoundPort(WebApplication app)
    {
        var addresses = app.Services.GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()?.Addresses;

        var address = addresses?.FirstOrDefault()
                      ?? throw new IOException("Kestrel reported no bound address.");

        return new Uri(address).Port;
    }

    public async ValueTask DisposeAsync()
    {
        if (_app is not null)
        {
            await _app.DisposeAsync().ConfigureAwait(false);
            _app = null;
        }
    }
}
