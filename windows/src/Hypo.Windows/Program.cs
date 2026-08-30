using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Hypo.Core.Abstractions;
using Hypo.Core.Discovery;
using Hypo.Core.History;
using Hypo.Core.Pairing;
using Hypo.Core.Relay;
using Hypo.Core.Sync;
using Hypo.Core.Transport;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows;

/// <summary>
/// A console client: discover, pair, then sync the real clipboard over the LAN
/// and the relay.
///
/// <para>No tray icon and no window. Those are the parts CI cannot judge, and
/// shipping them unverified alongside the parts it can would make a green badge
/// mean less than it does now.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public static class Program
{
    private static readonly string StateDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Hypo");

    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;

        Directory.CreateDirectory(StateDirectory);
        var store = new FileSecretStore(StateDirectory);

        var deviceId = LoadOrCreateDeviceId(store);
        var deviceName = Environment.GetEnvironmentVariable("HYPO_DEVICE_NAME") ?? Environment.MachineName;

        return (args.FirstOrDefault() ?? "run") switch
        {
            "discover" => await DiscoverAsync(),
            "pair" => await PairAsync(store, deviceId, deviceName, args.ElementAtOrDefault(1)),
            "run" => await RunAsync(store, deviceId, deviceName),
            var other => Usage(other),
        };
    }

    private static int Usage(string command)
    {
        Console.Error.WriteLine($"Unknown command '{command}'.");
        Console.Error.WriteLine("usage: hypo [discover | pair <device-id> | run]");
        return 2;
    }

    /// <summary>
    /// One identity per installation, kept with the keys.
    ///
    /// <para>A device id that changed between runs would make every existing
    /// pairing useless -- peers key on it -- so it is generated once and stored
    /// beside the keys it belongs with.</para>
    /// </summary>
    private static string LoadOrCreateDeviceId(ISecretStore store)
    {
        const string Key = "local-device-id";

        var stored = store.Read(Key);
        if (stored is not null)
        {
            return new Guid(stored).ToString();
        }

        var id = Guid.NewGuid();
        store.Write(Key, id.ToByteArray());
        return id.ToString();
    }

    private static async Task<int> DiscoverAsync()
    {
        await using var discovery = new MdnsPeerDiscovery();
        var found = new Dictionary<string, DiscoveredPeer>(StringComparer.OrdinalIgnoreCase);

        discovery.PeerDiscovered += (_, peer) =>
        {
            lock (found)
            {
                found[peer.DeviceId ?? peer.InstanceName] = peer;
            }
        };

        await discovery.StartBrowsingAsync();
        Console.WriteLine("Looking for peers...");

        for (var i = 0; i < 3; i++)
        {
            await Task.Delay(TimeSpan.FromSeconds(4));
            discovery.Refresh();
        }

        lock (found)
        {
            if (found.Count == 0)
            {
                Console.WriteLine("None found. Both devices must be on the same network.");
                return 1;
            }

            foreach (var peer in found.Values)
            {
                Console.WriteLine($"  {peer.DeviceId}  {peer.DisplayName}  {peer.Address}:{peer.Port}");
            }
        }

        return 0;
    }

    private static async Task<int> PairAsync(
        ISecretStore store, string deviceId, string deviceName, string? target)
    {
        if (string.IsNullOrWhiteSpace(target))
        {
            Console.Error.WriteLine("usage: hypo pair <device-id>   (run 'hypo discover' first)");
            return 2;
        }

        await using var discovery = new MdnsPeerDiscovery();
        var match = new TaskCompletionSource<DiscoveredPeer>(TaskCreationOptions.RunContinuationsAsynchronously);

        discovery.PeerDiscovered += (_, peer) =>
        {
            if (string.Equals(peer.DeviceId, target, StringComparison.OrdinalIgnoreCase))
            {
                match.TrySetResult(peer);
            }
        };

        await discovery.StartBrowsingAsync();

        DiscoveredPeer peer;
        try
        {
            peer = await match.Task.WaitAsync(TimeSpan.FromSeconds(15));
        }
        catch (TimeoutException)
        {
            Console.Error.WriteLine($"No peer advertising {target}. Run 'hypo discover' first.");
            return 1;
        }

        var result = await new LanPairingCoordinator(store)
            .PairAsync(peer, deviceId, deviceName);

        switch (result.Outcome)
        {
            case PairingOutcome.Paired:
                Console.WriteLine($"Paired with {result.PeerDeviceName} ({result.PeerDeviceId}).");
                return 0;

            case PairingOutcome.PeerAdvertisesNoKey:
                Console.Error.WriteLine($"{peer.DisplayName} advertises no key, so it cannot pair over the LAN.");
                return 1;

            case PairingOutcome.NoReply:
                Console.Error.WriteLine("Connected, but no pairing reply arrived. Is the peer's app in the foreground?");
                return 1;

            default:
                Console.Error.WriteLine("The pairing reply did not verify.");
                return 1;
        }
    }

    private static async Task<int> RunAsync(ISecretStore store, string deviceId, string deviceName)
    {
        // Only the GUID-shaped keys are peers: the store also holds this
        // device's own id and signing key.
        var peers = store.Keys()
            .Where(key => Guid.TryParse(key, out _))
            .ToArray();

        if (peers.Length == 0)
        {
            Console.Error.WriteLine("No paired devices. Run 'hypo pair <device-id>' first.");
            return 1;
        }

        using var clipboard = new ClipboardListener();
        using var history = new ClipboardHistoryStore(Path.Combine(StateDirectory, "history.db"));

        await using var server = new LanWebSocketServer();
        await server.StartAsync();

        await using var discovery = new MdnsPeerDiscovery();
        await discovery.AdvertiseAsync(deviceName, server.BoundPort, new Dictionary<string, string>
        {
            ["device_id"] = deviceId,
            ["version"] = "1.0.0-windows",
        });

        var cloud = new CloudWebSocketClient(
            RelayOptions.FromEnvironment(deviceId, "windows", searchFrom: AppContext.BaseDirectory));

        // The LAN half is the inbound server here; a peer dials us. Outbound
        // over the LAN needs a discovered peer, which the tray application will
        // manage -- for now the relay carries what the LAN cannot.
        await using var transport = new DualSyncTransport(new ServerTransport(server), cloud);

        var coordinator = new SyncCoordinator(clipboard, transport, store, history, deviceId, deviceName);
        foreach (var peer in peers)
        {
            coordinator.Peers.Add(peer);
        }

        coordinator.Applied += (_, entry) => Console.WriteLine(
            $"<- {entry.SourceDeviceName ?? entry.SourceDeviceId}: {Preview(entry)}");
        coordinator.Dropped += (_, reason) => Console.WriteLine($"   ({reason})");

        try
        {
            await transport.ConnectAsync();
        }
        catch (InvalidOperationException)
        {
            Console.Error.WriteLine("Neither the LAN nor the relay could be reached.");
            return 1;
        }

        Console.WriteLine($"{deviceName} ({deviceId}) syncing with {peers.Length} device(s).");
        Console.WriteLine($"LAN port {server.BoundPort}. Ctrl+C to stop.");

        await WaitForShutdownAsync();
        return 0;
    }

    private static string Preview(HistoryEntry entry) =>
        entry.Content.ContentType is Core.Protocol.ContentType.Text or Core.Protocol.ContentType.Link
            ? System.Text.Encoding.UTF8.GetString(entry.Content.Data)
            : $"{entry.Content.Data.Length} bytes";

    /// <summary>
    /// Returns on Ctrl+C or a termination request, so the callers' scopes unwind
    /// and the mDNS advertisement is withdrawn. Blocking forever leaves a stale
    /// record whose port points at a dead process, and a peer that resolves one
    /// gets silence -- indistinguishable from a sync bug.
    /// </summary>
    private static Task WaitForShutdownAsync()
    {
        var stopping = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        void Stop(PosixSignalContext context)
        {
            context.Cancel = true;
            stopping.TrySetResult();
        }

        var interrupt = PosixSignalRegistration.Create(PosixSignal.SIGINT, Stop);
        var terminate = PosixSignalRegistration.Create(PosixSignal.SIGTERM, Stop);

        return stopping.Task.ContinueWith(
            _ =>
            {
                interrupt.Dispose();
                terminate.Dispose();
            },
            TaskScheduler.Default);
    }
}

/// <summary>
/// Presents the inbound LAN server as a transport. It receives but cannot dial,
/// which is honest about what this build does: outbound LAN needs peer
/// selection, and until that exists the relay carries what the LAN cannot.
/// </summary>
internal sealed class ServerTransport(LanWebSocketServer server) : ISyncTransport
{
    public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived
    {
        add => server.EnvelopeReceived += value;
        remove => server.EnvelopeReceived -= value;
    }

    public event EventHandler<TransportStateChangedEventArgs>? StateChanged;

    public TransportState State => TransportState.Disconnected;

    public Task ConnectAsync(CancellationToken ct = default)
    {
        _ = StateChanged;
        return Task.CompletedTask;
    }

    public Task SendAsync(Core.Protocol.SyncEnvelope envelope, CancellationToken ct = default) =>
        throw new InvalidOperationException("The inbound LAN server cannot originate messages.");

    public Task DisconnectAsync(CancellationToken ct = default) => Task.CompletedTask;

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
