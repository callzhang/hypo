using System.IO;
using System.Net.Http;
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

        // Before anything can put a window on screen, including the
        // already-running message box below.
        ThemeHost.Follow(this);

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

        // Read before the client is built: the transports it brings up, the port
        // it binds and how much history it keeps are all decided here and cannot
        // be changed without starting again.
        var settingsPath = HypoSettings.PathIn(AppStartup.DefaultStateDirectory);
        var settings = HypoSettings.Load(settingsPath);

        // The stored name, falling back to the machine's. Taking the machine name
        // directly here is what made the setting cosmetic: peers kept seeing the
        // OS name however the field was edited.
        var result = await AppStartup.RunAsync(
            _clipboard, AppStartup.DefaultStateDirectory, settings.EffectiveDeviceName, settings: settings);

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

        _tray = new TrayIconHost(
            new ClientStatusSource(_client),
            new HistoryViewModel(_history, _clipboard),
            () => new PairingViewModel(
                store,
                new LanPairingCoordinator(store),
                deviceId,
                settings.EffectiveDeviceName,
                _client.Coordinator,
                new RemotePairingCoordinator(new RelayPairingClient(new HttpClient()), store)),
            Shutdown,
            _client,
            settings,
            updated => updated.Save(settingsPath),
            privacy => _clipboard.Privacy = privacy,
            // The tray hands in the settings in force and its own writer, so a
            // switch that appears in both the menu and the window is applied and
            // saved by one piece of code either way.
            (current, save) => new SettingsViewModel(
                store,
                _history,
                new ClientStatusSource(_client),
                current,
                save,
                StartupRegistration.IsEnabled,
                enabled => StartupRegistration.Set(
                    enabled, Environment.ProcessPath ?? AppContext.BaseDirectory)));

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
