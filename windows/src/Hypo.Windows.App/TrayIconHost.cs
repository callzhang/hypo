using System.Drawing;
using System.Windows;
using System.Windows.Forms;
using Hypo.Core.Client;
using Hypo.Core.Transport;
using Hypo.Windows.App;

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
    private readonly Action _shutdown;

    private readonly NotifyIcon _icon = new();
    private readonly System.Windows.Forms.Timer _poll = new();
    private readonly ToolStripMenuItem _pauseItem;

    private HistoryWindow? _historyWindow;
    private PairingWindow? _pairingWindow;
    private bool _paused;

    /// <summary>What the icon currently says. Exposed so a test can read it.</summary>
    public TrayStatus? Status { get; private set; }

    /// <summary>The menu, so its wiring can be exercised without a mouse.</summary>
    public ContextMenuStrip Menu => _icon.ContextMenuStrip!;

    /// <summary>Whether syncing is paused.</summary>
    public bool IsPaused => _paused;

    /// <summary>Recomputes the icon and tooltip now, rather than on the next tick.</summary>
    public void Refresh() => UpdateStatus();

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
        HypoClient? client = null)
    {
        _status = status;
        _client = client;
        _history = history;
        _pairing = pairing;
        _shutdown = shutdown;

        _pauseItem = new ToolStripMenuItem("Pause syncing", null, (_, _) => TogglePause());

        var menu = new ContextMenuStrip();
        menu.Items.Add(new ToolStripMenuItem("Clipboard history…", null, (_, _) => ShowHistory()));
        menu.Items.Add(new ToolStripMenuItem("Pair a device…", null, (_, _) => ShowPairing()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_pauseItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit Hypo", null, (_, _) => _shutdown()));

        _icon.ContextMenuStrip = menu;
        _icon.DoubleClick += (_, _) => ShowHistory();

        _poll.Interval = (int)PollInterval.TotalMilliseconds;
        _poll.Tick += (_, _) => UpdateStatus();
    }

    public void Start()
    {
        UpdateStatus();
        _icon.Visible = true;
        _poll.Start();
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
        }

        Surface(_historyWindow);
    }

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
        window.Topmost = true;
        window.Topmost = false;
        window.Focus();
    }

    public void Dispose()
    {
        _poll.Stop();
        _poll.Dispose();
        _icon.Visible = false;
        _icon.Dispose();
    }
}
