using System.IO;
using System.Text;
using System.Windows.Forms;
using Hypo.Core.Abstractions;
using Hypo.Core.History;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Core.Transport;
using Hypo.Windows.App;
using Hypo.Windows.App.Shell;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// The tray icon and its menu, driven without a mouse.
///
/// <para>This class has the most wiring in the application and had no tests,
/// because it took a whole <c>HypoClient</c> and therefore a relay connection
/// and a network. It takes a two-property status source now.</para>
/// </summary>
[Collection("wpf")]
public class TrayIconHostTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-tray").FullName;
    private readonly ClipboardHistoryStore _history;
    private readonly Status _status = new();

    public TrayIconHostTests() =>
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));

    public void Dispose()
    {
        _history.Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    private static void RequireWindows() =>
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

    private sealed class Status : ISyncStatusSource
    {
        public IReadOnlyCollection<string> LanPeers { get; set; } = [];

        public TransportState State { get; set; } = TransportState.Disconnected;
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

    private TrayIconHost Build(Action? shutdown = null)
    {
        var store = new InMemorySecretStore();

        return new TrayIconHost(
            _status,
            new HistoryViewModel(_history, new NullClipboard()),
            () => new PairingViewModel(
                store, new LanPairingCoordinator(store), "11111111-2222-3333-4444-555555555555", "Test PC"),
            shutdown ?? (() => { }));
    }

    [SkippableFact]
    public void TheIconFollowsWhatTheTransportsAreDoing()
    {
        RequireWindows();

        Wpf.Run(() =>
        {
            using var tray = Build();
            tray.Start();

            Assert.Equal(TrayIcon.Offline, tray.Status!.Icon);

            _status.State = TransportState.Connected;
            tray.Refresh();
            Assert.Equal(TrayIcon.RelayOnly, tray.Status!.Icon);

            _status.LanPeers = ["OPPO PLP110"];
            tray.Refresh();
            Assert.Equal(TrayIcon.Connected, tray.Status!.Icon);
        });
    }

    [SkippableFact]
    public void PausingChangesBothTheMenuAndTheIcon()
    {
        RequireWindows();

        _status.State = TransportState.Connected;
        _status.LanPeers = ["OPPO PLP110"];

        Wpf.Run(() =>
        {
            using var tray = Build();
            tray.Start();

            var pause = tray.Menu.Items.OfType<ToolStripMenuItem>()
                .Single(item => item.Text!.Contains("Pause", StringComparison.Ordinal));

            Assert.False(tray.IsPaused);
            Assert.Equal(TrayIcon.Connected, tray.Status!.Icon);

            pause.PerformClick();

            Assert.True(tray.IsPaused);
            Assert.Equal(TrayIcon.Paused, tray.Status!.Icon);

            // The label has to flip too, or the menu offers to pause something
            // that is already paused.
            Assert.Contains("Resume", pause.Text!, StringComparison.Ordinal);

            pause.PerformClick();

            Assert.False(tray.IsPaused);
            Assert.Contains("Pause", pause.Text!, StringComparison.Ordinal);
        });
    }

    [SkippableFact]
    public void TheMenuOffersWhatItShould()
    {
        RequireWindows();

        Wpf.Run(() =>
        {
            using var tray = Build();
            tray.Start();

            var labels = tray.Menu.Items.OfType<ToolStripMenuItem>()
                .Select(item => item.Text!)
                .ToArray();

            Assert.Contains(labels, l => l.Contains("history", StringComparison.OrdinalIgnoreCase));
            Assert.Contains(labels, l => l.Contains("Pair", StringComparison.OrdinalIgnoreCase));
            Assert.Contains(labels, l => l.Contains("Pause", StringComparison.OrdinalIgnoreCase));
            Assert.Contains(labels, l => l.Contains("Quit", StringComparison.OrdinalIgnoreCase));
        });
    }

    [SkippableFact]
    public void QuitAsksTheApplicationToStop()
    {
        RequireWindows();

        // A tray application with no other window is unquittable if this is
        // wrong, and the only way out is Task Manager.
        var stopped = false;

        Wpf.Run(() =>
        {
            using var tray = Build(shutdown: () => stopped = true);
            tray.Start();

            tray.Menu.Items.OfType<ToolStripMenuItem>()
                .Single(item => item.Text!.Contains("Quit", StringComparison.Ordinal))
                .PerformClick();
        });

        Assert.True(stopped);
    }

    [SkippableFact]
    public void OpeningHistoryFromTheMenuShowsAWindowWithTheEntries()
    {
        RequireWindows();

        _history.Add(new HistoryEntry
        {
            Content = new ClipboardContent
            {
                ContentType = ContentType.Text,
                Data = Encoding.UTF8.GetBytes("something copied earlier"),
            },
            CopiedAt = DateTimeOffset.UnixEpoch,
        });

        Wpf.Run(() =>
        {
            using var tray = Build();
            tray.Start();

            tray.Menu.Items.OfType<ToolStripMenuItem>()
                .Single(item => item.Text!.Contains("history", StringComparison.OrdinalIgnoreCase))
                .PerformClick();

            // Asking the tray what it opened, rather than WPF's global window
            // list: Application.Current belongs to whichever thread made it, and
            // reading its state from anywhere else fails.
            var window = tray.OpenHistoryWindow;

            Assert.NotNull(window);
            window!.Settle();

            var list = (System.Windows.Controls.ListBox)window.FindName("Rows");
            Assert.Single(list.Items);

            window.Capture("tray-history-window");
            window.Close();
        });
    }

    [SkippableFact]
    public void TheTooltipNamesThePeerItCanReach()
    {
        RequireWindows();

        _status.State = TransportState.Connected;
        _status.LanPeers = ["OPPO PLP110"];

        Wpf.Run(() =>
        {
            using var tray = Build();
            tray.Start();

            Assert.Contains("OPPO PLP110", tray.Status!.Tooltip, StringComparison.Ordinal);
        });
    }

    [SkippableFact]
    public void ManyLongPeerNamesDoNotTakeTheIconOutOfTheTray()
    {
        RequireWindows();

        // The test that would have caught the real bug here. TrayStatus.ClipTooltip
        // was added and tested, and the tray host went on using its own inline
        // truncation for a commit -- covered by nothing, because every test
        // exercised the helper directly instead of the host that has to call it.
        _status.State = TransportState.Connected;
        _status.LanPeers =
        [
            "A phone with an unusually long device name",
            "A laptop with an equally unreasonable name",
            "And a third, for good measure",
            "And a fourth",
        ];

        Wpf.Run(() =>
        {
            using var tray = Build();

            // Start throws if the tooltip reaches NotifyIcon unclipped.
            tray.Start();

            Assert.True(tray.Status!.Tooltip.Length > 63, "the status was not long enough to test clipping");
        });
    }

    [SkippableFact]
    public void DisposingTakesTheIconOutOfTheTray()
    {
        RequireWindows();

        // The classic tray bug: the process exits and its icon sits there until
        // someone hovers over it. NotifyIcon has to be hidden explicitly.
        Wpf.Run(() =>
        {
            var tray = Build();
            tray.Start();

            var icon = tray.GetType()
                .GetField("_icon", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!
                .GetValue(tray) as System.Windows.Forms.NotifyIcon;

            Assert.NotNull(icon);
            Assert.True(icon!.Visible);

            tray.Dispose();

            Assert.False(icon.Visible);
        });
    }

    [SkippableFact]
    public void OpeningHistoryTwiceReusesTheSameWindow()
    {
        RequireWindows();

        // Otherwise every click from the menu leaves another copy behind.
        Wpf.Run(() =>
        {
            using var tray = Build();
            tray.Start();

            var history = tray.Menu.Items.OfType<ToolStripMenuItem>()
                .Single(item => item.Text!.Contains("history", StringComparison.OrdinalIgnoreCase));

            history.PerformClick();
            var first = tray.OpenHistoryWindow;

            history.PerformClick();

            Assert.NotNull(first);
            Assert.Same(first, tray.OpenHistoryWindow);

            first!.Close();
        });
    }

    [SkippableFact]
    public void ReopeningAfterClosingGivesAFreshWindow()
    {
        RequireWindows();

        // And the opposite: once it has been closed, clicking again has to work
        // rather than trying to show a dead window.
        Wpf.Run(() =>
        {
            using var tray = Build();
            tray.Start();

            var history = tray.Menu.Items.OfType<ToolStripMenuItem>()
                .Single(item => item.Text!.Contains("history", StringComparison.OrdinalIgnoreCase));

            history.PerformClick();
            var first = tray.OpenHistoryWindow;
            first!.Close();

            Assert.Null(tray.OpenHistoryWindow);

            history.PerformClick();

            Assert.NotNull(tray.OpenHistoryWindow);
            Assert.NotSame(first, tray.OpenHistoryWindow);

            tray.OpenHistoryWindow!.Close();
        });
    }

    [SkippableFact]
    public void AMinimisedWindowComesBackWhenTheMenuIsUsedAgain()
    {
        RequireWindows();

        // Show() alone leaves a minimised window minimised, so the menu item
        // would appear to do nothing.
        Wpf.Run(() =>
        {
            using var tray = Build();
            tray.Start();

            var history = tray.Menu.Items.OfType<ToolStripMenuItem>()
                .Single(item => item.Text!.Contains("history", StringComparison.OrdinalIgnoreCase));

            history.PerformClick();
            var window = tray.OpenHistoryWindow!;
            window.WindowState = System.Windows.WindowState.Minimized;

            history.PerformClick();

            Assert.Equal(System.Windows.WindowState.Normal, window.WindowState);

            window.Close();
        });
    }
}
