using System.IO;
using System.Threading;
using System.Windows;
using Hypo.Core.Abstractions;
using Hypo.Core.Client;
using Hypo.Core.History;
using Hypo.Core.Pairing;
using Hypo.Core.Relay;
using Hypo.Windows.App;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows.App.Shell;

/// <summary>
/// Starts the client and hands it to a tray icon.
///
/// <para>This class wires; it does not decide. Everything with a rule in it --
/// what the icon means, how history filters, what a pairing failure says -- is
/// in <c>Hypo.Windows</c> where it has tests, because nothing here can be run on
/// the machine it is written on.</para>
/// </summary>
public partial class App : System.Windows.Application
{
    /// <summary>
    /// Named per user rather than globally: two people signed into the same
    /// machine each get their own clipboard, and a global mutex would let the
    /// first to log in silently block the second.
    /// </summary>
    private static readonly string InstanceMutexName =
        $"Local\\Hypo.Windows.App.{Environment.UserName}";

    private static readonly string StateDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Hypo");

    private Mutex? _instance;
    private TrayIconHost? _tray;
    private HypoClient? _client;
    private ClipboardListener? _clipboard;
    private ClipboardHistoryStore? _history;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _instance = new Mutex(initiallyOwned: true, InstanceMutexName, out var isFirst);
        if (!isFirst)
        {
            // Two copies both listening on the LAN port and both writing the
            // clipboard is a fight the user gets to watch.
            System.Windows.MessageBox.Show(
                "Hypo is already running. Look for it in the notification area.",
                "Hypo", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Information);
            Shutdown();
            return;
        }

        try
        {
            await StartAsync();
        }
        catch (Exception ex)
        {
            // Failing to start is the one error the user cannot see in the tray,
            // because there is no tray yet.
            System.Windows.MessageBox.Show(
                $"Hypo could not start.\n\n{ex.Message}",
                "Hypo", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Error);
            Shutdown();
        }
    }

    private async Task StartAsync()
    {
        Directory.CreateDirectory(StateDirectory);

        var store = new FileSecretStore(StateDirectory);
        var deviceId = LoadOrCreateDeviceId(store);
        var deviceName = Environment.MachineName;

        _clipboard = new ClipboardListener();
        _history = new ClipboardHistoryStore(Path.Combine(StateDirectory, "history.db"));

        _client = HypoClient.Create(
            _clipboard,
            store,
            _history,
            deviceId,
            deviceName,
            RelayOptions.FromEnvironment(deviceId, "windows", searchFrom: AppContext.BaseDirectory));

        _tray = new TrayIconHost(
            _client,
            new HistoryViewModel(_history, _clipboard),
            () => new PairingViewModel(
                store, new LanPairingCoordinator(store), deviceId, deviceName, _client.Coordinator),
            Shutdown);

        await _client.StartAsync();
        _tray.Start();
    }

    /// <summary>
    /// One identity per installation, stored beside the keys it belongs with. A
    /// device id that changed between runs would make every existing pairing
    /// useless, since peers key on it.
    /// </summary>
    private static string LoadOrCreateDeviceId(ISecretStore store)
    {
        const string Key = "local-device-id";

        if (store.Read(Key) is { } stored)
        {
            return new Guid(stored).ToString();
        }

        var id = Guid.NewGuid();
        store.Write(Key, id.ToByteArray());
        return id.ToString();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _client?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        _clipboard?.Dispose();
        _history?.Dispose();
        _instance?.Dispose();

        base.OnExit(e);
    }
}
