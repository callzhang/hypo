using Hypo.Core.Abstractions;
using Hypo.Core.Client;
using Hypo.Core.Discovery;
using Hypo.Core.History;
using Hypo.Core.Relay;
using Hypo.Core.Sync;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

/// <summary>
/// Turning a transport off.
///
/// <para>A transport that is never connected is skipped by everything
/// downstream, because sending already checks each channel's state. These tests
/// hold that: switching one off must not need a special case anywhere else, and
/// must not throw.</para>
/// </summary>
public class HypoClientTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-client").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private sealed class RecordingDiscovery : IPeerDiscovery
    {
        public event EventHandler<DiscoveredPeer>? PeerDiscovered;

        public bool Advertised { get; private set; }

        public bool Browsed { get; private set; }

        public Task AdvertiseAsync(
            string deviceName, int port, IReadOnlyDictionary<string, string> txt, CancellationToken ct = default)
        {
            _ = PeerDiscovered;
            Advertised = true;
            return Task.CompletedTask;
        }

        public Task StartBrowsingAsync(CancellationToken ct = default)
        {
            Browsed = true;
            return Task.CompletedTask;
        }

        public IReadOnlyCollection<DiscoveredPeer> KnownPeers => [];

        public void Refresh()
        {
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class NullClipboard : IClipboard
    {
        public event EventHandler<ClipboardContent>? ContentChanged;

        public Task<ClipboardContent?> GetAsync(CancellationToken ct = default)
        {
            _ = ContentChanged;
            return Task.FromResult<ClipboardContent?>(null);
        }

        public Task SetAsync(ClipboardContent content, CancellationToken ct = default) => Task.CompletedTask;
    }

    /// <summary>A relay nothing is listening on, so connecting it must fail.</summary>
    private static RelayOptions Unreachable => new()
    {
        // Port 1 on the loopback: refused immediately rather than after a
        // timeout, so a test that expects the cloud not to be tried stays fast.
        Endpoint = new Uri("ws://127.0.0.1:1/ws"),
        Secret = "not-a-real-secret",
        DeviceId = "11111111-2222-3333-4444-555555555555",
        Platform = "windows",
    };

    private async Task<(HypoClient Client, RecordingDiscovery Discovery)> StartAsync(
        bool lan, bool cloud, int port = 0)
    {
        var discovery = new RecordingDiscovery();
        var history = new ClipboardHistoryStore(Path.Combine(_dir, $"h-{Guid.NewGuid():N}.db"));

        var client = HypoClient.Create(
            new NullClipboard(),
            new InMemorySecretStore(),
            history,
            "11111111-2222-3333-4444-555555555555",
            "Test PC",
            Unreachable,
            discovery,
            lanPort: port,
            ownsHistory: true,
            lanEnabled: lan,
            cloudEnabled: cloud);

        await client.StartAsync();

        return (client, discovery);
    }

    [Fact]
    public async Task WithTheLanOffNothingIsAdvertisedOrBrowsed()
    {
        // Not a cosmetic difference: advertising is what puts this machine's
        // name and address on the network, and someone turning the LAN off is
        // usually asking for exactly that to stop.
        var (client, discovery) = await StartAsync(lan: false, cloud: false);
        await using var _ = client;

        Assert.False(discovery.Advertised);
        Assert.False(discovery.Browsed);
    }

    [Fact]
    public async Task WithTheLanOnItAdvertisesAndBrowses()
    {
        var (client, discovery) = await StartAsync(lan: true, cloud: false);
        await using var _ = client;

        Assert.True(discovery.Advertised);
        Assert.True(discovery.Browsed);
    }

    [Fact]
    public async Task WithTheRelayOffAnUnreachableRelayIsNotAnError()
    {
        // The point of the switch: this relay cannot be reached, and starting
        // must not fail because of a channel nobody asked for.
        var (client, _) = await StartAsync(lan: true, cloud: false);
        await using var __ = client;

        Assert.NotEqual(TransportState.Faulted, client.State);
    }

    [Fact]
    public async Task WithBothOffStartingStillSucceeds()
    {
        // An application that keeps a history and syncs with nobody. A choice
        // someone is entitled to make, and it must not look like a crash.
        var (client, _) = await StartAsync(lan: false, cloud: false);
        await using var __ = client;

        Assert.Equal(TransportState.Disconnected, client.State);
        Assert.Empty(client.LanPeers);
    }
}
