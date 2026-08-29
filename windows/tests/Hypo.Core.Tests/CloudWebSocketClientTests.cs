using System.Buffers.Binary;
using System.Text;
using Hypo.Core.Protocol;
using Hypo.Core.Relay;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class CloudWebSocketClientTests
{
    private const string DeviceId = "11111111-2222-3333-4444-555555555555";
    private const string PeerId = "bbe296d6-0785-43d2-91b6-b135b72f4c41";
    private const string Secret = "hypo-test-secret";

    private static RelayOptions Options(Uri endpoint) => new()
    {
        Endpoint = endpoint,
        Secret = Secret,
        DeviceId = DeviceId,
        Platform = "windows",
    };

    /// <summary>
    /// Substitutes %ID% and %PEER% rather than interpolating: these bodies end
    /// in runs of closing braces, and raw-string interpolation needs one more
    /// '$' than the longest run, which is a counting exercise nobody wins.
    /// </summary>
    private static byte[] Frame(string json, Guid? id = null) =>
        FrameBytes(json.Replace("%ID%", (id ?? Guid.Empty).ToString())
                       .Replace("%PEER%", PeerId)
                       .Replace("%SELF%", DeviceId));

    private static byte[] FrameBytes(string json)
    {
        var body = Encoding.UTF8.GetBytes(json);
        var framed = new byte[4 + body.Length];
        BinaryPrimitives.WriteUInt32BigEndian(framed, (uint)body.Length);
        body.CopyTo(framed.AsSpan(4));
        return framed;
    }

    private static SyncEnvelope Envelope() => new()
    {
        Id = Guid.NewGuid(),
        Timestamp = DateTimeOffset.UtcNow,
        Type = MessageType.Clipboard,
        Payload = new EnvelopePayload
        {
            ContentType = ContentType.Text,
            Ciphertext = [1, 2, 3],
            DeviceId = DeviceId,
            Encryption = new EncryptionMetadata { Nonce = new byte[12], Tag = new byte[16] },
        },
    };

    [Fact]
    public async Task SendsTheThreeUpgradeHeaders()
    {
        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        await client.ConnectAsync();
        await relay.WaitForConnectionAsync();

        Assert.Equal(DeviceId, relay.Headers!["X-Device-Id"]);
        Assert.Equal("windows", relay.Headers["X-Device-Platform"]);
        Assert.Equal(RelayAuthToken.Compute(Secret, DeviceId), relay.Headers["X-Auth-Token"]);
    }

    [Fact]
    public async Task ConnectsWithoutWaitingForAGreeting()
    {
        // The relay sends nothing on connect. A client that waits for a welcome
        // frame waits forever, so the open socket is the whole handshake.
        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        await client.ConnectAsync();

        Assert.Equal(TransportState.Connected, client.State);
    }

    [Fact]
    public async Task SendsALengthPrefixedBinaryFrame()
    {
        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));
        await client.ConnectAsync();

        await client.SendAsync(Envelope());

        var frame = await relay.NextFrameAsync();
        Assert.Equal((uint)(frame.Length - 4), BinaryPrimitives.ReadUInt32BigEndian(frame));
        Assert.Equal((byte)'{', frame[4]);
    }

    [Fact]
    public async Task RaisesReceivedEnvelopesWithCloudOrigin()
    {
        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        var seen = new TaskCompletionSource<EnvelopeReceivedEventArgs>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.EnvelopeReceived += (_, e) => seen.TrySetResult(e);

        await client.ConnectAsync();
        await relay.SendAsync(Frame("""
            {"id":"%ID%","timestamp":"2026-08-29T21:54:28Z","version":"1.0",
             "type":"clipboard","payload":{"content_type":"text","ciphertext":"AQID",
             "device_id":"%PEER%","encryption":{"nonce":"AAAAAAAAAAAAAAAA","tag":"AAAAAAAAAAAAAAAAAAAAAA=="}}}
            """, Guid.NewGuid()));

        var received = await seen.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(TransportOrigin.Cloud, received.Origin);

        // No handshake to learn the peer from, unlike the LAN, so it comes from
        // the body -- unauthenticated until decryption checks it against the AAD.
        Assert.Equal(PeerId, received.PeerDeviceId);
    }

    [Fact]
    public async Task SurfacesAnUndeliverableMessageAsAnErrorRatherThanThrowing()
    {
        // Verbatim from the live relay on 2026-08-29. Its payload has no
        // ciphertext and no encryption block, both of which EnvelopePayload
        // requires, so a strict decode throws on the first offline peer -- and
        // an offline peer is not an edge case, it is Tuesday.
        var messageId = Guid.NewGuid();

        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        var faulted = new TaskCompletionSource<TransportStateChangedEventArgs>();
        client.StateChanged += (_, e) =>
        {
            if (e.State == TransportState.Faulted)
            {
                faulted.TrySetResult(e);
            }
        };

        var envelopes = 0;
        client.EnvelopeReceived += (_, _) => Interlocked.Increment(ref envelopes);

        var error = new TaskCompletionSource<RelayError>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.RelayErrorReceived += (_, e) => error.TrySetResult(e.Error);

        await client.ConnectAsync();
        await relay.SendAsync(Frame("""
            {"id":"%ID%","type":"error","version":"1.0",
             "timestamp":"2026-08-29T21:54:28.509290711+00:00",
             "payload":{"code":"device_not_connected",
                        "message":"Target device 99999999-0000-0000-0000-000000000000 is not connected to the relay server. Device may be offline or disconnected.",
                        "original_message_id":"%ID%",
                        "target_device_id":"99999999-0000-0000-0000-000000000000",
                        "connected_devices":["%PEER%","%SELF%"]}}
            """, messageId));

        var received = await error.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal("device_not_connected", received.Code);
        Assert.Equal("99999999-0000-0000-0000-000000000000", received.TargetDeviceId);
        Assert.Equal(messageId, received.OriginalMessageId);
        Assert.Contains(PeerId, received.ConnectedDevices);
        Assert.Equal(0, envelopes);
        Assert.False(faulted.Task.IsCompleted);
        Assert.Equal(TransportState.Connected, client.State);
    }

    [Fact]
    public async Task ReusesTheSentMessageIdAsTheErrorEnvelopeId()
    {
        // Worth pinning on its own: the relay does not mint a fresh id for the
        // error, it echoes ours. Dedup keyed on envelope id alone will treat an
        // undeliverable message as one it has already handled.
        var messageId = Guid.NewGuid();

        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        var error = new TaskCompletionSource<RelayError>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.RelayErrorReceived += (_, e) => error.TrySetResult(e.Error);

        await client.ConnectAsync();
        await relay.SendAsync(Frame("""
            {"id":"%ID%","type":"error","version":"1.0","timestamp":"2026-08-29T21:54:28Z",
             "payload":{"code":"device_not_connected","original_message_id":"%ID%"}}
            """, messageId));

        Assert.Equal(messageId, (await error.Task.WaitAsync(TimeSpan.FromSeconds(5))).OriginalMessageId);
    }

    [Fact]
    public async Task IgnoresUnknownMessageTypesWithoutDroppingTheConnection()
    {
        // The relay is shared infrastructure and may grow message kinds before
        // this client learns about them.
        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        var envelopes = 0;
        client.EnvelopeReceived += (_, _) => Interlocked.Increment(ref envelopes);

        await client.ConnectAsync();
        await relay.SendAsync(FrameBytes("""{"id":"x","type":"something_new","payload":{}}"""));
        await relay.SendAsync(FrameBytes("not json at all"));

        await client.SendAsync(Envelope());
        await relay.NextFrameAsync();

        Assert.Equal(0, envelopes);
        Assert.Equal(TransportState.Connected, client.State);
    }

    [Fact]
    public async Task RefusesToSendWhileDisconnected()
    {
        await using var client = new CloudWebSocketClient(Options(new Uri("ws://127.0.0.1:1/ws")));

        await Assert.ThrowsAsync<InvalidOperationException>(() => client.SendAsync(Envelope()));
    }
}
