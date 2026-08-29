using Hypo.Core.Discovery;

namespace Hypo.Core.Tests;

public class DiscoveredPeerTests
{
    // Exactly what a live macOS peer advertised, measured on a real network.
    private static readonly Dictionary<string, string> MacOsTxt = new()
    {
        ["signing_pub_key"] = "S4ItgzBJTsac1lN8T05Zpk7ZvudGjYKycnOTEheTzsg=",
        ["device_id"] = "007e4a95-0e1a-4b10-91fa-87942efaa68e",
        ["pub_key"] = "0KWinOak3zMKXjQg4K1f7TWdypF0oDb32e5fOnzjuX4=",
        ["version"] = "1.1.6",
        ["fingerprint_sha256"] = "259a3c4c3f4d1288fb15def2db2655aeac4bbe0575d8b756c053d4d369a76b34",
        ["protocols"] = "ws+tls",
    };

    private static DiscoveredPeer MacOsPeer() => DiscoveredPeer.FromTxt(
        instanceName: @"derek\8217s\032MacBook\032Air\032(2)._hypo._tcp.local",
        host: "4efa9cc4-2ea7-468c-9b64-7087849da0b4.local",
        address: "10.0.0.252",
        port: 7010,
        txt: MacOsTxt);

    [Fact]
    public void ExposesTheUnescapedDisplayName()
    {
        Assert.Equal("derek’s MacBook Air (2)", MacOsPeer().DisplayName);
    }

    [Fact]
    public void ParsesTheTypedTxtProperties()
    {
        var peer = MacOsPeer();

        Assert.Equal("007e4a95-0e1a-4b10-91fa-87942efaa68e", peer.DeviceId);
        Assert.Equal(32, peer.PublicKey!.Length);
        Assert.Equal(32, peer.SigningPublicKey!.Length);
        Assert.Equal("1.1.6", peer.Version);
    }

    [Fact]
    public void LowercasesTheDeviceId()
    {
        var txt = new Dictionary<string, string>(MacOsTxt)
        {
            ["device_id"] = "007E4A95-0E1A-4B10-91FA-87942EFAA68E",
        };

        var peer = DiscoveredPeer.FromTxt("x._hypo._tcp.local", "h", "1.2.3.4", 7010, txt);

        Assert.Equal("007e4a95-0e1a-4b10-91fa-87942efaa68e", peer.DeviceId);
    }

    [Fact]
    public void IgnoresTheAdvertisedProtocolsField()
    {
        // Both shipping clients announce ws+tls and neither implements TLS.
        // Honouring it would make every connection fail, so it is not surfaced
        // as anything a caller can act on.
        Assert.Null(typeof(DiscoveredPeer).GetProperty("Protocols"));
        Assert.Equal("ws+tls", MacOsPeer().Txt["protocols"]);
    }

    [Fact]
    public void ToleratesAPeerAdvertisingNoPairingKeys()
    {
        var peer = DiscoveredPeer.FromTxt(
            "x._hypo._tcp.local", "h", "1.2.3.4", 7010, new Dictionary<string, string>());

        Assert.Null(peer.DeviceId);
        Assert.Null(peer.PublicKey);
        Assert.Null(peer.SigningPublicKey);
        Assert.Equal("x", peer.DisplayName);
    }

    [Fact]
    public void ToleratesAMalformedKey()
    {
        var txt = new Dictionary<string, string> { ["pub_key"] = "not base64!" };

        var peer = DiscoveredPeer.FromTxt("x._hypo._tcp.local", "h", "1.2.3.4", 7010, txt);

        Assert.Null(peer.PublicKey);
    }

    [Fact]
    public void BuildsTheWebSocketUriFromTheAddressNotTheHostname()
    {
        // The macOS peer advertises its device UUID as a .local hostname, which
        // needs mDNS resolution to reach. The A record is already in hand.
        Assert.Equal("ws://10.0.0.252:7010/", MacOsPeer().WebSocketUri.ToString());
    }
}
