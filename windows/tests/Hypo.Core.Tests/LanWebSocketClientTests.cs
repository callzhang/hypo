using Hypo.Core.Discovery;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class LanWebSocketClientTests
{
    private const string LocalDeviceId = "550e8400-e29b-41d4-a716-446655440000";

    private static DiscoveredPeer Peer() => DiscoveredPeer.FromTxt(
        instanceName: "peer._hypo._tcp.local",
        host: "peer.local",
        address: "10.0.0.17",
        port: 7010,
        txt: new Dictionary<string, string> { ["device_id"] = "bbe296d6-0785-43d2-91b6-b135b72f4c41" });

    [Fact]
    public void DialsTheAddressWithTheDeviceIdOnTheQueryString()
    {
        var uri = LanWebSocketClient.BuildUri(Peer(), LocalDeviceId);

        Assert.Equal("ws", uri.Scheme);
        Assert.Equal("10.0.0.17", uri.Host);
        Assert.Equal(7010, uri.Port);
        Assert.Contains($"device_id={LocalDeviceId}", uri.Query, StringComparison.Ordinal);
    }

    [Fact]
    public void NeverDialsWss()
    {
        // Peers advertise protocols=ws+tls and none of them implement it.
        // Honouring that field would make every connection fail.
        var txt = new Dictionary<string, string> { ["protocols"] = "ws+tls" };
        var peer = DiscoveredPeer.FromTxt("p._hypo._tcp.local", "h", "10.0.0.1", 7010, txt);

        Assert.Equal("ws", LanWebSocketClient.BuildUri(peer, LocalDeviceId).Scheme);
    }

    [Fact]
    public void LowercasesTheLocalDeviceIdOnTheWire()
    {
        var uri = LanWebSocketClient.BuildUri(Peer(), LocalDeviceId.ToUpperInvariant());

        Assert.Contains($"device_id={LocalDeviceId}", uri.Query, StringComparison.Ordinal);
    }

    [Fact]
    public void StartsDisconnected()
    {
        using var client = new LanWebSocketClient(Peer(), LocalDeviceId);

        Assert.Equal(TransportState.Disconnected, client.State);
    }

    [Fact]
    public async Task SendingBeforeConnectingThrows()
    {
        using var client = new LanWebSocketClient(Peer(), LocalDeviceId);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => client.SendAsync(TestEnvelopes.Clipboard(LocalDeviceId)));
    }
}
