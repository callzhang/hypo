using Hypo.Core.Discovery;

namespace Hypo.Core.Tests;

public class MdnsPeerDiscoveryTests
{
    [Fact]
    public void IgnoresInstancesOfOtherServiceTypes()
    {
        // ServiceInstanceDiscovered fires for every service on the network; the
        // spike saw AirPlay, Spotify Connect and Roku. Without this filter the
        // device list fills with televisions.
        Assert.False(MdnsPeerDiscovery.IsHypoInstance("65in TCL Roku TV._airplay._tcp.local"));
        Assert.False(MdnsPeerDiscovery.IsHypoInstance("x._spotify-connect._tcp.local"));
        Assert.True(MdnsPeerDiscovery.IsHypoInstance("OPPO PLP110._hypo._tcp.local"));
    }

    [Fact]
    public void MatchesTheServiceTypeCaseInsensitively()
    {
        Assert.True(MdnsPeerDiscovery.IsHypoInstance("X._HYPO._TCP.LOCAL"));
    }

    [Fact]
    public void BuildsAPeerOnlyWhenSrvAndAddressAreBothKnown()
    {
        var records = new MdnsRecordSet();
        var instance = "OPPO PLP110._hypo._tcp.local";

        Assert.Null(records.TryBuildPeer(instance));

        records.NoteSrv(instance, "Android_TCDVBQQI.local", 7010);
        Assert.Null(records.TryBuildPeer(instance));

        records.NoteAddress("Android_TCDVBQQI.local", "10.0.0.17");
        var peer = records.TryBuildPeer(instance);

        Assert.NotNull(peer);
        Assert.Equal("10.0.0.17", peer.Address);
        Assert.Equal(7010, peer.Port);
    }

    [Fact]
    public void CarriesTxtPropertiesOntoThePeer()
    {
        var records = new MdnsRecordSet();
        var instance = "OPPO PLP110._hypo._tcp.local";
        records.NoteSrv(instance, "h.local", 7010);
        records.NoteAddress("h.local", "10.0.0.17");
        records.NoteTxt(instance, new Dictionary<string, string>
        {
            ["device_id"] = "BBE296D6-0785-43D2-91B6-B135B72F4C41",
            ["pub_key"] = "ZuPQTwT2QainOfqI5TikmthXtYGM6ENfrtH3szCnfEo=",
        });

        var peer = records.TryBuildPeer(instance)!;

        Assert.Equal("bbe296d6-0785-43d2-91b6-b135b72f4c41", peer.DeviceId);
        Assert.Equal(32, peer.PublicKey!.Length);
    }

    [Fact]
    public void ALaterSrvRecordReplacesAnEarlierOne()
    {
        // A peer that changes IP re-announces; the newest record wins.
        var records = new MdnsRecordSet();
        var instance = "x._hypo._tcp.local";
        records.NoteSrv(instance, "old.local", 7010);
        records.NoteAddress("old.local", "10.0.0.5");
        records.NoteSrv(instance, "new.local", 7011);
        records.NoteAddress("new.local", "10.0.0.6");

        var peer = records.TryBuildPeer(instance)!;

        Assert.Equal("10.0.0.6", peer.Address);
        Assert.Equal(7011, peer.Port);
    }
}
