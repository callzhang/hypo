using System.Drawing;
using System.Windows;
using System.Windows.Forms;
using Hypo.Core.Client;
using Hypo.Core.Transport;
using Hypo.Windows.App;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows.App.Shell;

/// <summary>
/// The notification-area icon and its menu.
///
/// <para>WinForms' <see cref="NotifyIcon"/> rather than a WPF equivalent: WPF has
/// none, and every third-party wrapper is a dependency around this same class.</para>
///
/// <para>What the icon <em>means</em> is <see cref="TrayStatus"/>'s job, which is
/// tested. This only renders it and pumps a timer.</para>
/// </summary>
public sealed class TrayIconHost : IDisposable
{
    /// <summary>
    /// Nothing pushes a "peer appeared" event up here, so the status is polled.
    /// Two seconds is below the threshold where a user starts wondering whether
    /// the icon is stuck, and far above anything that costs power.
    /// </summary>
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

    private readonly ISyncStatusSource _status;
    private readonly HypoClient? _client;
    private readonly HistoryViewModel _history;
    private readonly Func<PairingViewModel> _pairing;
    private readonly Func<HypoSettings, Action<HypoSettings>, SettingsViewModel>? _settingsModel;
    private readonly Action _shutdown;

    private readonly NotifyIcon _icon = new();
    private readonly System.Windows.Forms.Timer _poll = new();
    private readonly ToolStripMenuItem _pauseItem;
    private ToolStripMenuItem _historyMenuItem = null!;
    private readonly ToolStripMenuItem _historyItem;
    private readonly ToolStripMenuItem _cloudItem;
    private readonly ToolStripMenuItem _notifyItem;
    private readonly Action<HypoSettings> _saveSettings;
    private HypoSettings _settings;

    private readonly ForegroundHandoff _handoff = new();
    private GlobalHotkey? _hotkey;

    private HistoryWindow? _historyWindow;
    private PairingWindow? _pairingWindow;
    private SettingsWindow? _settingsWindow;
    private bool _paused;

    /// <summary>What the icon currently says. Exposed so a test can read it.</summary>
    public TrayStatus? Status { get; private set; }

    /// <summary>The menu, so its wiring can be exercised without a mouse.</summary>
    public ContextMenuStrip Menu => _icon.ContextMenuStrip!;

    /// <summary>Whether syncing is paused.</summary>
    public bool IsPaused => _paused;

    /// <summary>Recomputes the icon and tooltip now, rather than on the next tick.</summary>
    public void Refresh() => UpdateStatus();

    /// <summary>The sharing settings as they currently stand.</summary>
    public HypoSettings Settings => _settings;

    private readonly Action<ClipboardPrivacy> _applyPrivacy;

    /// <summary>
    /// Applies a change immediately and writes it down.
    ///
    /// <para>Applied before saving: a setting that took effect only after a
    /// restart is one people reasonably conclude did not work, and this one
    /// governs where their clipboard goes.</para>
    /// </summary>
    private void Update(HypoSettings settings)
    {
        _settings = settings;

        _applyPrivacy(settings.Privacy);
        _saveSettings(settings);

        _historyItem.Checked = settings.ShareWithWindowsHistory;
        _cloudItem.Checked = settings.AllowCloudClipboardUpload;
        _notifyItem.Checked = settings.NotifyOnArrival;

        // The settings window shows the same three. Handing it the new settings
        // rather than asking it to redraw: its model holds the ones it was built
        // with, so a bare rebind draws the same stale values.
        _settingsWindow?.Adopt(settings);
    }

    /// <summary>The history window while it is open, and null once it is closed.</summary>
    public Window? OpenHistoryWindow => _historyWindow;

    /// <summary>The pairing window while it is open.</summary>
    public Window? OpenPairingWindow => _pairingWindow;

    /// <param name="client">
    /// Optional, and only so the pairing window can watch for peers arriving
    /// while it is open. Everything else the tray needs comes through
    /// <paramref name="status"/>, which is what makes this class testable at all.
    /// </param>
    public TrayIconHost(
        ISyncStatusSource status,
        HistoryViewModel history,
        Func<PairingViewModel> pairing,
        Action shutdown,
        HypoClient? client = null,
        HypoSettings? settings = null,
        Action<HypoSettings>? saveSettings = null,
        Action<ClipboardPrivacy>? applyPrivacy = null,
        Func<HypoSettings, Action<HypoSettings>, SettingsViewModel>? settingsModel = null)
    {
        _status = status;
        _client = client;
        _settings = settings ?? new HypoSettings();
        _saveSettings = saveSettings ?? (_ => { });
        _applyPrivacy = applyPrivacy ?? (_ => { });
        _history = history;
        _pairing = pairing;
        _settingsModel = settingsModel;
        _shutdown = shutdown;

        _pauseItem = new ToolStripMenuItem("Pause syncing", null, (_, _) => TogglePause());

        // Both start off. The labels say what turning them on does rather than
        // naming a feature, because "Share with Windows clipboard history" is
        // only meaningful if you already know what that is.
        _historyMenuItem = new ToolStripMenuItem(
            "Clipboard history…", null, (_, _) => ShowHistory());

        _historyItem = new ToolStripMenuItem(
            "Show synced items in Windows clipboard history (Win+V)",
            null,
            (_, _) => Update(_settings with { ShareWithWindowsHistory = !_settings.ShareWithWindowsHistory }))
        {
            CheckOnClick = false,
            Checked = _settings.ShareWithWindowsHistory,
        };

        _cloudItem = new ToolStripMenuItem(
            "Let Windows upload synced items to your Microsoft account",
            null,
            (_, _) => Update(_settings with { AllowCloudClipboardUpload = !_settings.AllowCloudClipboardUpload }))
        {
            CheckOnClick = false,
            Checked = _settings.AllowCloudClipboardUpload,
        };

        _notifyItem = new ToolStripMenuItem(
            "Tell me when something arrives from another device",
            null,
            (_, _) => Update(_settings with { NotifyOnArrival = !_settings.NotifyOnArrival }))
        {
            CheckOnClick = false,
            Checked = _settings.NotifyOnArrival,
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add(_historyMenuItem);
        menu.Items.Add(new ToolStripMenuItem("Pair a device…", null, (_, _) => ShowPairing()));

        // Only the composition root has the history store and the secret store
        // the settings window needs, so it is handed in. Without one there is
        // nothing to show and the item would be a dead end.
        if (_settingsModel is not null)
        {
            menu.Items.Add(new ToolStripMenuItem("Settings…", null, (_, _) => ShowSettings()));
        }
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_historyItem);
        menu.Items.Add(_cloudItem);
        menu.Items.Add(_notifyItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_pauseItem);
        menu.Items.Add(new ToolStripSeparator());

        // Disabled on purpose: it is a label, not a command. The first question
        // anyone asks about a sync bug is which version each end is running, and
        // a tray application has nowhere else to say it.
        menu.Items.Add(new ToolStripMenuItem($"Hypo {AppVersion.Current}") { Enabled = false });
        menu.Items.Add(new ToolStripMenuItem("Quit Hypo", null, (_, _) => _shutdown()));

        _icon.ContextMenuStrip = menu;
        _icon.DoubleClick += (_, _) => ShowHistory();

        _poll.Interval = (int)PollInterval.TotalMilliseconds;
        _poll.Tick += (_, _) => UpdateStatus();
    }

    public void Start()
    {
        // So the listener starts out matching what the menu shows.
        _applyPrivacy(_settings.Privacy);

        UpdateStatus();
        _icon.Visible = true;
        _poll.Start();

        ShowFirewallNoticeOnce();
        RegisterHotkey();
        AnnounceArrivals();
    }

    /// <summary>
    /// Claims the key combination that opens the history, and says so in the
    /// menu either way.
    ///
    /// <para>A hotkey that silently does nothing is indistinguishable from a
    /// broken application, so a refusal -- almost always another application
    /// already holding the combination -- goes where the user will look.</para>
    /// </summary>
    private void RegisterHotkey()
    {
        // Pressed arrives on the hotkey's own message pump. Everything ShowHistory
        // touches is WPF, so it has to be handed back here -- and asynchronously,
        // so holding the keys down cannot block that pump.
        var ui = System.Windows.Threading.Dispatcher.CurrentDispatcher;

        _hotkey = new GlobalHotkey(_settings.HotkeyBinding);
        _hotkey.Pressed += (_, _) => ui.BeginInvoke(ShowHistory);

        _historyMenuItem.Text = _hotkey.IsRegistered
            ? $"Clipboard history…\t{_hotkey.Binding}"
            : "Clipboard history…";

        if (_hotkey.Failure is { } failure)
        {
            _icon.BalloonTipTitle = "Hypo's shortcut is unavailable";
            _icon.BalloonTipText = $"{failure} Open the history from this menu instead.";
            _icon.BalloonTipIcon = ToolTipIcon.Warning;
            _icon.ShowBalloonTip(10_000);
        }
    }

    /// <summary>
    /// Says when something arrives from another device.
    ///
    /// <para>Only remote arrivals: <c>Applied</c> fires for inbound items alone,
    /// and <see cref="ArrivalNotice"/> checks again, because notifying someone
    /// about the thing they just copied themselves is noise.</para>
    /// </summary>
    private void AnnounceArrivals()
    {
        if (_client is null)
        {
            return;
        }

        _client.Coordinator.Applied += (_, entry) =>
        {
            if (!_settings.NotifyOnArrival || ArrivalNotice.For(entry) is not { } notice)
            {
                return;
            }

            Announce(notice);
        };
    }

    /// <summary>The last thing said, for the tests.</summary>
    public ArrivalNotice? LastAnnouncement { get; private set; }

    /// <summary>
    /// Shows a notice.
    ///
    /// <para>A balloon rather than the Windows App SDK's AppNotificationManager
    /// that the design named: that needs the application to be packaged, and
    /// Hypo ships as a zip. A balloon is a real toast on Windows 10 and 11.</para>
    /// </summary>
    public void Announce(ArrivalNotice notice)
    {
        LastAnnouncement = notice;

        _icon.BalloonTipTitle = notice.Title;
        _icon.BalloonTipText = notice.Body;
        _icon.BalloonTipIcon = ToolTipIcon.Info;
        _icon.ShowBalloonTip(5_000);
    }

    /// <summary>The hotkey's state, for anyone showing it.</summary>
    public string? HotkeyFailure => _hotkey?.Failure;

    public bool HotkeyRegistered => _hotkey?.IsRegistered ?? false;

    /// <summary>
    /// Explains the firewall prompt, once, on the first run.
    ///
    /// <para>Windows asks which networks to allow the moment a LAN port is
    /// bound, and the answer decides whether local sync works at all. Someone
    /// who dismisses it, or picks "Public networks" on their home Wi-Fi, ends up
    /// with a client that silently only ever uses the relay.</para>
    ///
    /// <para>A balloon rather than a dialog: this is worth reading and not worth
    /// interrupting anyone for, and a modal box on first launch is how an
    /// application teaches people to dismiss its messages unread.</para>
    /// </summary>
    private void ShowFirewallNoticeOnce()
    {
        if (_settings.FirewallNoticeShown)
        {
            return;
        }

        _icon.BalloonTipTitle = "Hypo is starting";
        _icon.BalloonTipText =
            "Windows may ask which networks to allow. Choose Private networks, or "
            + "devices on this network will not be able to reach this PC.";
        _icon.BalloonTipIcon = ToolTipIcon.Info;
        _icon.ShowBalloonTip(10_000);

        // Written down immediately: shown-and-not-recorded means shown again on
        // every launch, which is worse than not showing it.
        //
        // Not through Update: nothing about the sharing settings changed, and
        // re-applying privacy and rewriting menu checkmarks to record one flag
        // makes Start do more than it looks like it does.
        _settings = _settings with { FirewallNoticeShown = true };
        _saveSettings(_settings);
    }

    private void TogglePause()
    {
        _paused = !_paused;
        _pauseItem.Text = _paused ? "Resume syncing" : "Pause syncing";
        UpdateStatus();
    }

    private void UpdateStatus()
    {
        Status = TrayStatus.From(
            _status.LanPeers.Count > 0 ? TransportState.Connected : TransportState.Disconnected,
            _status.State,
            _status.LanPeers.ToArray(),
            _paused);

        _icon.Icon = IconFor(Status.Icon);

        // Through ClipTooltip, which is tested. NotifyIcon.Text throws on a long
        // value rather than truncating, so getting this wrong takes the icon out
        // of the tray entirely.
        _icon.Text = TrayStatus.ClipTooltip(Status.Tooltip);
    }

    /// <summary>
    /// Drawn rather than shipped as assets: four states, each a filled circle, and
    /// an .ico per state would be four more files to keep in step with the enum.
    /// </summary>
    private static Icon IconFor(Hypo.Windows.App.TrayIcon state)
    {
        var colour = state switch
        {
            Hypo.Windows.App.TrayIcon.Connected => Color.FromArgb(0x2E, 0xA0, 0x43),
            Hypo.Windows.App.TrayIcon.RelayOnly => Color.FromArgb(0xD2, 0x9A, 0x00),
            Hypo.Windows.App.TrayIcon.Paused => Color.FromArgb(0x8A, 0x8A, 0x8A),
            _ => Color.FromArgb(0xC0, 0x39, 0x2B),
        };

        using var bitmap = new Bitmap(16, 16);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            graphics.Clear(Color.Transparent);
            using var brush = new SolidBrush(colour);
            graphics.FillEllipse(brush, 2, 2, 12, 12);
        }

        return Icon.FromHandle(bitmap.GetHicon());
    }

    private void ShowHistory()
    {
        _history.Refresh();

        if (_historyWindow is null)
        {
            _historyWindow = new HistoryWindow(_history);
            _historyWindow.Closed += (_, _) => _historyWindow = null;
            _historyWindow.EntryUsed += (_, _) => _handoff.Return();
        }

        // Before showing: showing is what takes the foreground away.
        _handoff.Capture();

        Surface(_historyWindow);
        _historyWindow.ReadyToType();
    }

    /// <summary>The settings window while it is open.</summary>
    public Window? OpenSettingsWindow => _settingsWindow;

    private void ShowSettings()
    {
        if (_settingsModel is null)
        {
            return;
        }

        if (_settingsWindow is null)
        {
            // Built through the tray's own Update so the switches it shares with
            // this menu are applied and saved by one piece of code. Two paths
            // writing the same setting is how a menu ends up disagreeing with a
            // window.
            _settingsWindow = new SettingsWindow(_settingsModel(_settings, Update), ShowPairing)
            {
                HotkeyStatus = HotkeyDescription,
            };
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }

        _settingsWindow.Bind();
        Surface(_settingsWindow);
    }

    /// <summary>
    /// The shortcut, or why it is not working -- the design puts this in
    /// Settings, which is the only place with room to explain it.
    /// </summary>
    public string? HotkeyDescription => _hotkey switch
    {
        null => null,
        { Failure: { } failure } => $"Shortcut: {failure} Open the history from the tray menu instead.",
        var hotkey => $"Shortcut: {hotkey.Binding} opens the clipboard history.",
    };

    private void ShowPairing()
    {
        if (_pairingWindow is null)
        {
            _pairingWindow = new PairingWindow(_pairing(), _client);
            _pairingWindow.Closed += (_, _) => _pairingWindow = null;
        }

        Surface(_pairingWindow);
    }

    /// <summary>
    /// Shows a window and brings it forward. Activate alone leaves it behind
    /// whatever the user is doing when it was already open but buried.
    /// </summary>
    private static void Surface(Window window)
    {
        window.Show();

        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }

        window.Activate();

        // The false-then-true toggle is what pulls a window in front of whatever
        // had the foreground. Ending on the value the window declared matters:
        // the history window asks to stay on top, and finishing on false took
        // that away from it every time it was opened.
        var stayOnTop = window.Topmost;

        window.Topmost = false;
        window.Topmost = true;
        window.Topmost = stayOnTop;

        window.Focus();
    }

    public void Dispose()
    {
        // Left registered, the combination stays claimed for the session and the
        // next launch cannot have it.
        _hotkey?.Dispose();

        _poll.Stop();
        _poll.Dispose();
        _icon.Visible = false;
        _icon.Dispose();
    }
}
