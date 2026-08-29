using Hypo.Core.Relay;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class CloudReconnectTests
{
    private const string DeviceId = "11111111-2222-3333-4444-555555555555";

    private static RelayOptions Options(Uri endpoint) => new()
    {
        Endpoint = endpoint,
        Secret = "hypo-test-secret",
        DeviceId = DeviceId,
        Platform = "windows",

        // Real values are seconds to minutes; the behaviour under test is the
        // decision to retry, not the wait.
        ReconnectInitialDelay = TimeSpan.FromMilliseconds(20),
        ReconnectMaxDelay = TimeSpan.FromMilliseconds(80),
    };

    private static async Task<bool> Eventually(Func<bool> condition, TimeSpan? within = null)
    {
        var deadline = DateTime.UtcNow + (within ?? TimeSpan.FromSeconds(5));
        while (DateTime.UtcNow < deadline)
        {
            if (condition())
            {
                return true;
            }

            await Task.Delay(20);
        }

        return condition();
    }

    [Fact]
    public async Task ComesBackAfterTheRelayDropsTheConnection()
    {
        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        await client.ConnectAsync();
        await relay.WaitForConnectionAsync();

        relay.DropCurrentConnection();

        Assert.True(await Eventually(() => relay.Connections >= 2),
            $"expected a reconnection, saw {relay.Connections} connection(s)");
        Assert.True(await Eventually(() => client.State == TransportState.Connected));
    }

    [Fact]
    public async Task StopsRetryingWhenTheRelayRejectsTheCredentials()
    {
        // A wrong shared secret would otherwise hammer a service other people
        // depend on, forever, and no amount of waiting turns a 401 into a 101.
        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        // Wait for the *rejection*, not for any fault: dropping the socket
        // faults the transport on its own, before the retry that gets refused.
        var rejected = new TaskCompletionSource<RelayRejectedException>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.StateChanged += (_, e) =>
        {
            if (e.Error is RelayRejectedException rejection)
            {
                rejected.TrySetResult(rejection);
            }
        };

        await client.ConnectAsync();
        await relay.WaitForConnectionAsync();

        relay.RejectWith = 401;
        relay.DropCurrentConnection();

        var refusal = await rejected.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(System.Net.HttpStatusCode.Unauthorized, refusal.Status);

        // The original connection plus exactly one refused retry, and then it
        // stops -- rather than backing off politely forever against a service
        // other people depend on.
        var afterRejection = relay.Connections;
        await Task.Delay(500);

        Assert.Equal(afterRejection, relay.Connections);
        Assert.Equal(2, relay.Connections);
    }

    [Fact]
    public async Task ARejectedFirstConnectionThrowsAndDoesNotRetry()
    {
        await using var relay = await StubRelayServer.StartAsync();
        relay.RejectWith = 401;

        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        await Assert.ThrowsAnyAsync<Exception>(() => client.ConnectAsync());
        Assert.Equal(TransportState.Faulted, client.State);

        await Task.Delay(300);
        Assert.Equal(1, relay.Connections);
    }

    [Fact]
    public async Task DisconnectStopsReconnection()
    {
        await using var relay = await StubRelayServer.StartAsync();
        await using var client = new CloudWebSocketClient(Options(relay.Uri));

        await client.ConnectAsync();
        await relay.WaitForConnectionAsync();

        await client.DisconnectAsync();
        var afterDisconnect = relay.Connections;

        await Task.Delay(400);

        Assert.Equal(afterDisconnect, relay.Connections);
        Assert.Equal(TransportState.Disconnected, client.State);
    }

    [Fact]
    public void KeepaliveDefaultsUnderTheRelayIdleTimeout()
    {
        // backend/fly.toml sets http_options.idle_timeout = 900. The relay never
        // pings first, so anything at or above the ceiling means the socket is
        // closed under us on every idle link.
        var options = new RelayOptions
        {
            Endpoint = new Uri(RelayOptions.DefaultEndpoint),
            Secret = "s",
            DeviceId = DeviceId,
            Platform = "windows",
        };

        Assert.True(options.KeepAliveInterval < TimeSpan.FromSeconds(900));
        Assert.Equal(TimeSpan.FromSeconds(840), options.KeepAliveInterval);
    }
}
