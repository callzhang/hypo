using Hypo.Core.Discovery;

namespace Hypo.Core.Tests;

/// <summary>
/// Requires a real Hypo peer on the same network. Enable with HYPO_LIVE_PEER=1.
/// </summary>
public class LivePeerDiscoveryTests
{
    private static bool Enabled =>
        Environment.GetEnvironmentVariable("HYPO_LIVE_PEER") == "1";

    [SkippableFact]
    public async Task DiscoversAtLeastOneRealPeer()
    {
        Skip.IfNot(Enabled, "Set HYPO_LIVE_PEER=1 with a macOS or Android peer on the network.");

        await using var discovery = new MdnsPeerDiscovery();
        var found = new List<DiscoveredPeer>();
        discovery.PeerDiscovered += (_, peer) => { lock (found) { found.Add(peer); } };

        await discovery.StartBrowsingAsync();
        for (var i = 0; i < 3; i++)
        {
            await Task.Delay(TimeSpan.FromSeconds(5));
            discovery.Refresh();
        }

        DiscoveredPeer[] peers;
        lock (found) { peers = found.ToArray(); }

        Assert.NotEmpty(peers);

        foreach (var peer in peers)
        {
            Assert.EndsWith("._hypo._tcp.local", peer.InstanceName, StringComparison.OrdinalIgnoreCase);
            Assert.False(string.IsNullOrWhiteSpace(peer.Address));
            Assert.InRange(peer.Port, 1, 65535);
            Assert.DoesNotContain("\\0", peer.DisplayName, StringComparison.Ordinal);
        }
    }

    [SkippableFact]
    public async Task RealPeersAdvertisePairingMaterial()
    {
        Skip.IfNot(Enabled, "Set HYPO_LIVE_PEER=1 with a macOS or Android peer on the network.");

        await using var discovery = new MdnsPeerDiscovery();
        await discovery.StartBrowsingAsync();
        await Task.Delay(TimeSpan.FromSeconds(12));

        var pairable = discovery.KnownPeers
            .Where(p => p.DeviceId is not null && p.PublicKey is not null)
            .ToArray();

        Assert.NotEmpty(pairable);

        foreach (var peer in pairable)
        {
            Assert.True(Guid.TryParse(peer.DeviceId, out _), $"device_id was '{peer.DeviceId}'");
            Assert.Equal(peer.DeviceId, peer.DeviceId!.ToLowerInvariant());
            Assert.Equal(32, peer.PublicKey!.Length);
            Assert.Equal(32, peer.SigningPublicKey!.Length);
        }
    }
}
