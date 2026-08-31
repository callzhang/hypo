using System.IO;
using Hypo.Core.Abstractions;
using Hypo.Core.Discovery;
using Hypo.Core.Pairing;
using Hypo.Core.Transport;
using Hypo.Windows.App;
using Hypo.Windows.App.Shell;

namespace Hypo.Windows.App.Tests;

[Collection("wpf")]
public class TrayAndPairingTests
{
    private const string LocalId = "11111111-2222-3333-4444-555555555555";
    private const string PeerId = "bbe296d6-0785-43d2-91b6-b135b72f4c41";

    private static void RequireWindows() =>
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

    private static DiscoveredPeer Peer(string name, string deviceId) => DiscoveredPeer.FromTxt(
        instanceName: $"{name}._hypo._tcp.local",
        host: "phone.local",
        address: "10.0.0.17",
        port: 7010,
        txt: new Dictionary<string, string>
        {
            ["device_id"] = deviceId,
            ["pub_key"] = Convert.ToBase64String(new byte[32]),
        });

    [SkippableFact]
    public void ANotificationAreaIconCanBeShownAndTakenAway()
    {
        RequireWindows();

        // The runner turns out to allow this. Which means "does the tray icon
        // appear" stopped being a question only a person on Windows could answer.
        Wpf.Run(() =>
        {
            using var icon = new System.Windows.Forms.NotifyIcon
            {
                Icon = System.Drawing.SystemIcons.Application,
                Text = "Hypo — probe",
            };

            icon.Visible = true;
            Assert.True(icon.Visible);

            icon.Visible = false;
            Assert.False(icon.Visible);
        });
    }

    [SkippableFact]
    public void EveryClippedTooltipIsAcceptedByTheTrayIcon()
    {
        RequireWindows();

        // NotifyIcon.Text throws on a long value rather than truncating, which
        // would take the icon out entirely. This checks the clipping against the
        // real control instead of against a remembered limit -- 64 characters
        // turns out to be fine, so the historic 63-character figure is not the
        // boundary and guessing at it is how this breaks.
        var longest = TrayStatus.From(
            TransportState.Connected,
            TransportState.Connected,
            ["A device with a rather long name", "And another one", "A third"]);

        Wpf.Run(() =>
        {
            using var icon = new System.Windows.Forms.NotifyIcon();
            icon.Text = TrayStatus.ClipTooltip(longest.Tooltip);
            Assert.NotEmpty(icon.Text);
        });
    }

    [SkippableFact]
    public void AnUnclippedTooltipWouldBreakTheTrayIcon()
    {
        RequireWindows();

        // Why the clipping exists, pinned rather than described.
        Wpf.Run(() =>
        {
            using var icon = new System.Windows.Forms.NotifyIcon();
            Assert.ThrowsAny<ArgumentException>(() => icon.Text = new string('x', 200));
        });
    }

    [SkippableFact]
    public void ThePairingWindowShowsDiscoveredDevices()
    {
        RequireWindows();

        var store = new InMemorySecretStore();
        store.Write(PeerId, new byte[32]);

        var model = new PairingViewModel(
            store, new LanPairingCoordinator(store), LocalId, "Test PC");

        model.Observe(Peer("OPPO PLP110", PeerId));
        model.Observe(Peer("derek's MacBook Air", "007e4a95-0e1a-4b10-91fa-87942efaa68e"));

        Wpf.Run(() =>
        {
            var window = new PairingWindow(model);
            window.Show();
            window.Settle();

            var list = (System.Windows.Controls.ListBox)window.FindName("Peers");
            Assert.Equal(2, list.Items.Count);

            var pixels = window.Capture("pairing-window");
            Assert.True(Wpf.HasVisibleContent(pixels), "the window rendered blank");

            window.Close();
        });
    }

    [SkippableFact]
    public void ThePairingWindowSaysWhenNothingIsSelected()
    {
        RequireWindows();

        var store = new InMemorySecretStore();
        var model = new PairingViewModel(store, new LanPairingCoordinator(store), LocalId, "Test PC");
        model.Observe(Peer("OPPO PLP110", PeerId));

        Wpf.Run(() =>
        {
            var window = new PairingWindow(model);
            window.Show();
            window.Settle();

            var button = (System.Windows.Controls.Button)window.FindName("PairButton");
            var message = (System.Windows.Controls.TextBlock)window.FindName("Message");

            // Clicking with nothing chosen must say so rather than doing nothing,
            // which is indistinguishable from being broken.
            button.RaiseEvent(new System.Windows.RoutedEventArgs(
                System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.Settle();

            Assert.Contains("Choose a device", message.Text, StringComparison.Ordinal);

            window.Capture("pairing-window-nothing-selected");
            window.Close();
        });
    }

    [SkippableFact]
    public void ScreenshotsAreWrittenWhereCiCanCollectThem()
    {
        RequireWindows();

        // The point of all of this: someone with no Windows machine can look at
        // the interface. This renders its own window rather than depending on
        // another test having run first, which xunit does not promise.
        Wpf.Run(() =>
        {
            var window = new System.Windows.Window
            {
                Width = 200,
                Height = 80,
                Content = new System.Windows.Controls.TextBlock { Text = "screenshot probe" },
            };
            window.Show();
            window.Capture("screenshot-mechanism");
            window.Close();
        });

        Assert.True(
            File.Exists(Path.Combine(Wpf.ScreenshotDirectory, "screenshot-mechanism.png")),
            $"no screenshot in {Wpf.ScreenshotDirectory}");
    }

    [SkippableFact]
    public void TheCodeControlsAreHiddenWhenThereIsNoRelay()
    {
        RequireWindows();

        // Hidden rather than disabled-and-mysterious: a control that does
        // nothing invites a bug report.
        var store = new InMemorySecretStore();
        var model = new PairingViewModel(store, new LanPairingCoordinator(store), LocalId, "Test PC");

        Wpf.Run(() =>
        {
            var window = new PairingWindow(model);
            window.Show();
            window.Settle();

            Assert.Equal(
                System.Windows.Visibility.Collapsed,
                ((System.Windows.Controls.Button)window.FindName("ShowCodeButton")).Visibility);

            window.Capture("pairing-window-no-relay");
            window.Close();
        });
    }

    [SkippableFact]
    public void TheCodeControlsAppearWhenPairingByCodeIsPossible()
    {
        RequireWindows();

        var store = new InMemorySecretStore();
        var model = new PairingViewModel(
            store,
            new LanPairingCoordinator(store),
            LocalId,
            "Test PC",
            sync: null,
            remote: new RemotePairingCoordinator(
                new RelayPairingClient(new System.Net.Http.HttpClient()), store));

        model.Observe(Peer("OPPO PLP110", PeerId.ToString()));

        Wpf.Run(() =>
        {
            var window = new PairingWindow(model);
            window.Show();
            window.Settle();

            Assert.Equal(
                System.Windows.Visibility.Visible,
                ((System.Windows.Controls.Button)window.FindName("ShowCodeButton")).Visibility);
            Assert.Equal(
                System.Windows.Visibility.Visible,
                ((System.Windows.Controls.TextBox)window.FindName("CodeBox")).Visibility);

            var pixels = window.Capture("pairing-window-with-code");
            Assert.True(Wpf.HasVisibleContent(pixels), "the window rendered blank");

            window.Close();
        });
    }
}
