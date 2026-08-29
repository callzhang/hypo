using System.Net;
using System.Net.WebSockets;
using Hypo.Core.Discovery;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Hypo.Core.Tests;

/// <summary>
/// The binary channel carries two different things. Android replies to a
/// pairing challenge with bare JSON on a binary frame — Java-WebSocket's
/// send(byte[]) is opcode 0x2 and it has no text-send path — while clipboard
/// traffic is a length-prefixed envelope on the same opcode. The opcode alone
/// therefore cannot tell them apart, and the content has to.
/// </summary>
public class BinaryChannelClassificationTests
{
    private const string ClientId = "550e8400-e29b-41d4-a716-446655440000";
    private static readonly Guid ServerId = Guid.Parse("bbe296d6-0785-43d2-91b6-b135b72f4c41");

    private const string AckJson =
        """{"challenge_id":"c0ffee","responder_device_id":"bbe296d6-0785-43d2-91b6-b135b72f4c41","responder_device_name":"OPPO PLP110"}""";

    private static DiscoveredPeer PeerOn(int port) => DiscoveredPeer.FromTxt(
        "server._hypo._tcp.local", "localhost", "127.0.0.1", port,
        new Dictionary<string, string> { ["device_id"] = ServerId.ToString("D") });

    [Fact]
    public async Task ABareJsonBinaryFrameArrivesAsAPairingMessage()
    {
        // The exact shape Android sends: '{' is 0x7B, which no length prefix
        // under the 20 MB ceiling can start with.
        await using var peer = await AndroidLikePeer.StartAsync(
            System.Text.Encoding.UTF8.GetBytes(AckJson));

        await using var client = new LanWebSocketClient(PeerOn(peer.Port), ClientId);
        var pairing = new TaskCompletionSource<string>();
        client.PairingMessageReceived += (_, e) => pairing.TrySetResult(e.Json);
        await client.ConnectAsync();

        var json = await pairing.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.StartsWith("{", json, StringComparison.Ordinal);
        Assert.Contains("\"challenge_id\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ABareJsonBinaryFrameDoesNotFaultTheTransport()
    {
        // What Task 18 measured: FrameReader reads '{"ch' as 2,065,851,240
        // bytes, throws past the ceiling, and the pump faults the connection.
        await using var peer = await AndroidLikePeer.StartAsync(
            System.Text.Encoding.UTF8.GetBytes(AckJson));

        await using var client = new LanWebSocketClient(PeerOn(peer.Port), ClientId);
        var pairing = new TaskCompletionSource<string>();
        client.PairingMessageReceived += (_, e) => pairing.TrySetResult(e.Json);
        await client.ConnectAsync();

        await pairing.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.NotEqual(TransportState.Faulted, client.State);
    }

    [Fact]
    public async Task AZeroLeadingLengthPrefixIsStillAnEnvelope()
    {
        // Every realistic clipboard frame is under 16 MB, so its length prefix
        // leads with 0x00. That must keep reaching FrameReader.
        await using var server = new LanWebSocketServer(port: 0);
        var received = new TaskCompletionSource<EnvelopeReceivedEventArgs>();
        var pairing = new TaskCompletionSource<string>();
        server.EnvelopeReceived += (_, e) => received.TrySetResult(e);
        server.PairingMessageReceived += (_, e) => pairing.TrySetResult(e.Json);
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();
        var sent = TestEnvelopes.Clipboard(ClientId, [0xDE, 0xAD]);
        await client.SendAsync(sent);

        var got = await received.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(sent.Id, got.Envelope.Id);
        Assert.False(pairing.Task.IsCompleted);
    }

    [Fact]
    public async Task AOneLeadingLengthPrefixIsStillTreatedAsAFrame()
    {
        // The boundary from the other side: 0x013FFFF0 is 20,971,504 bytes,
        // just under the 20,971,520 ceiling, so it is a legal prefix and must
        // not be mistaken for JSON. Only the prefix is sent; the frame stays
        // incomplete in the reader, which is exactly the observable difference
        // from being handed to the pairing channel.
        await using var server = new LanWebSocketServer(port: 0);
        var pairing = new TaskCompletionSource<string>();
        server.PairingMessageReceived += (_, e) => pairing.TrySetResult(e.Json);
        await server.StartAsync();

        using var raw = new ClientWebSocket();
        await raw.ConnectAsync(
            new Uri($"ws://127.0.0.1:{server.BoundPort}/?device_id={ClientId}"), CancellationToken.None);
        await raw.SendAsync(
            new byte[] { 0x01, 0x3F, 0xFF, 0xF0 },
            WebSocketMessageType.Binary,
            true,
            CancellationToken.None);

        var settled = await Task.WhenAny(pairing.Task, Task.Delay(TimeSpan.FromSeconds(2)));

        Assert.NotSame(pairing.Task, settled);
    }

    [Fact]
    public async Task ATextFrameIsStillAPairingMessage()
    {
        // macOS replies on opcode 0x1. Splitting the binary channel must not
        // disturb the channel that was already right.
        await using var server = new LanWebSocketServer(port: 0);
        var pairing = new TaskCompletionSource<string>();
        server.PairingMessageReceived += (_, e) => pairing.TrySetResult(e.Json);
        await server.StartAsync();

        using var raw = new ClientWebSocket();
        await raw.ConnectAsync(
            new Uri($"ws://127.0.0.1:{server.BoundPort}/?device_id={ClientId}"), CancellationToken.None);
        await raw.SendAsync(
            System.Text.Encoding.UTF8.GetBytes(AckJson),
            WebSocketMessageType.Text,
            true,
            CancellationToken.None);

        var json = await pairing.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Contains("\"challenge_id\"", json, StringComparison.Ordinal);
    }

    /// <summary>
    /// Stands in for the phone: accepts a connection and immediately pushes one
    /// binary frame carrying bare JSON, the way LanWebSocketServer.sendPairingAck
    /// does on Android. LanWebSocketServer cannot play this part — it only ever
    /// replies with opcode 0x1.
    /// </summary>
    private sealed class AndroidLikePeer : IAsyncDisposable
    {
        private readonly WebApplication _app;

        private AndroidLikePeer(WebApplication app, int port)
        {
            _app = app;
            Port = port;
        }

        public int Port { get; }

        public static async Task<AndroidLikePeer> StartAsync(byte[] reply)
        {
            var builder = WebApplication.CreateSlimBuilder();
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 0));

            var app = builder.Build();
            app.UseWebSockets();
            app.Use(async (HttpContext context, RequestDelegate _) =>
            {
                if (!context.WebSockets.IsWebSocketRequest)
                {
                    context.Response.StatusCode = StatusCodes.Status400BadRequest;
                    return;
                }

                using var socket = await context.WebSockets.AcceptWebSocketAsync();
                await socket.SendAsync(reply, WebSocketMessageType.Binary, true, context.RequestAborted);

                var sink = new byte[1024];
                while (socket.State == WebSocketState.Open && !context.RequestAborted.IsCancellationRequested)
                {
                    var result = await socket.ReceiveAsync(sink, context.RequestAborted);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        break;
                    }
                }
            });

            await app.StartAsync();

            var address = app.Services.GetRequiredService<IServer>()
                .Features.Get<IServerAddressesFeature>()!.Addresses.First();

            return new AndroidLikePeer(app, new Uri(address).Port);
        }

        public ValueTask DisposeAsync() => _app.DisposeAsync();
    }
}
