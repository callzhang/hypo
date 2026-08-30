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
    private Mutex? _instance;
    private TrayIconHost? _tray;
    private HypoClient? _client;
    private ClipboardListener? _clipboard;
    private ClipboardHistoryStore? _history;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _instance = new Mutex(initiallyOwned: true, AppStartup.MutexNameFor(Environment.UserName), out var isFirst);
        if (!isFirst)
        {
            // Two copies both listening on the LAN port and both writing the
            // clipboard is a fight the user gets to watch.
            Tell("Hypo is already running. Look for it in the notification area.",
                System.Windows.MessageBoxImage.Information);
            Shutdown();
            return;
        }

        _clipboard = new ClipboardListener();

        var result = await AppStartup.RunAsync(
            _clipboard, AppStartup.DefaultStateDirectory, Environment.MachineName);

        if (!result.Started)
        {
            // Every one of these is a sentence, not a stack trace -- Startup
            // returns them rather than throwing precisely so this can say
            // something useful instead of vanishing.
            Tell(result.Message, System.Windows.MessageBoxImage.Warning);
            Shutdown();
            return;
        }

        _client = result.Client!;
        _history = result.History!;

        var store = new FileSecretStore(AppStartup.DefaultStateDirectory);
        var deviceId = result.DeviceId!;

        var settingsPath = HypoSettings.PathIn(AppStartup.DefaultStateDirectory);

        _tray = new TrayIconHost(
            new ClientStatusSource(_client),
            new HistoryViewModel(_history, _clipboard),
            () => new PairingViewModel(
                store, new LanPairingCoordinator(store), deviceId, Environment.MachineName, _client.Coordinator),
            Shutdown,
            _client,
            HypoSettings.Load(settingsPath),
            settings => settings.Save(settingsPath),
            privacy => _clipboard.Privacy = privacy);

        _tray.Start();
    }

    private static void Tell(string message, System.Windows.MessageBoxImage image) =>
        System.Windows.MessageBox.Show(message, "Hypo", System.Windows.MessageBoxButton.OK, image);

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
