using System.Net;
using System.Net.WebSockets;
using System.Threading.Channels;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Hypo.Core.Tests;

/// <summary>
/// A stand-in for the relay, so the cloud client's tests do not depend on a
/// deployed service, a shared secret, or the network. It records the upgrade
/// headers, collects the frames the client sends, and lets a test push
/// arbitrary bytes back — including the malformed and the unexpected, which is
/// most of what these tests are about.
/// </summary>
internal sealed class StubRelayServer : IAsyncDisposable
{
    private readonly WebApplication _app;
    private readonly Channel<byte[]> _received = Channel.CreateUnbounded<byte[]>();
    private readonly Channel<WebSocket> _sockets = Channel.CreateUnbounded<WebSocket>();
    private WebSocket? _current;
    private int _connections;

    private StubRelayServer(WebApplication app, Uri uri)
    {
        _app = app;
        Uri = uri;
    }

    public Uri Uri { get; }

    /// <summary>How many upgrade requests have arrived. Reconnection is counted, not inferred.</summary>
    public int Connections => Volatile.Read(ref _connections);

    /// <summary>When set, every upgrade is refused with this status instead of accepted.</summary>
    public int? RejectWith { get; set; }

    /// <summary>Headers from the upgrade request, once a client has connected.</summary>
    public IHeaderDictionary? Headers { get; private set; }

    public static async Task<StubRelayServer> StartAsync()
    {
        var builder = WebApplication.CreateBuilder();
        builder.Logging.ClearProviders();

        // Listen on any free port. ListenLocalhost(0) throws, which is a trap
        // the LAN server hit first.
        builder.WebHost.ConfigureKestrel(o => o.Listen(IPAddress.Loopback, 0));

        var app = builder.Build();
        StubRelayServer? server = null;

        app.UseWebSockets();
        app.Run(async context =>
        {
            Interlocked.Increment(ref server!._connections);
            server.Headers = context.Request.Headers;

            if (server.RejectWith is { } status)
            {
                context.Response.StatusCode = status;
                return;
            }

            if (!context.WebSockets.IsWebSocketRequest)
            {
                context.Response.StatusCode = 400;
                return;
            }

            using var socket = await context.WebSockets.AcceptWebSocketAsync();
            server._current = socket;
            await server._sockets.Writer.WriteAsync(socket);
            await server.ReadLoopAsync(socket, context.RequestAborted);
        });

        await app.StartAsync();

        var address = app.Services
            .GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!
            .Addresses
            .First();
        var uri = new Uri(address.Replace("http://", "ws://", StringComparison.Ordinal));

        server = new StubRelayServer(app, uri);
        return server;
    }

    private async Task ReadLoopAsync(WebSocket socket, CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        try
        {
            while (socket.State == WebSocketState.Open)
            {
                var result = await socket.ReceiveAsync(buffer, ct);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    return;
                }

                await _received.Writer.WriteAsync(buffer[..result.Count], ct);
            }
        }
        catch (Exception ex) when (ex is OperationCanceledException or WebSocketException)
        {
            // The client going away is the normal end of a test.
        }
    }

    /// <summary>Waits for the client's next frame, failing the test rather than hanging.</summary>
    public async Task<byte[]> NextFrameAsync(TimeSpan? within = null)
    {
        using var timeout = new CancellationTokenSource(within ?? TimeSpan.FromSeconds(5));
        return await _received.Reader.ReadAsync(timeout.Token);
    }

    public async Task SendAsync(byte[] payload, WebSocketMessageType type = WebSocketMessageType.Binary)
    {
        var socket = _current ?? await WaitForConnectionAsync();
        await socket.SendAsync(payload, type, endOfMessage: true, CancellationToken.None);
    }

    /// <summary>Waits for the next upgrade to complete and returns its socket.</summary>
    public async Task<WebSocket> WaitForConnectionAsync(TimeSpan? within = null)
    {
        using var timeout = new CancellationTokenSource(within ?? TimeSpan.FromSeconds(5));
        return await _sockets.Reader.ReadAsync(timeout.Token);
    }

    /// <summary>
    /// Drops the current connection the way a relay restart would: abruptly,
    /// with no close handshake. A polite close is a different code path.
    /// </summary>
    public void DropCurrentConnection() => _current?.Abort();

    public async ValueTask DisposeAsync()
    {
        await _app.StopAsync();
        await _app.DisposeAsync();
    }
}
