using System.IO;
using Hypo.Core.Abstractions;
using Hypo.Core.Discovery;
using Hypo.Core.Pairing;
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

    [SkippableTheory]
    [InlineData(63)]
    [InlineData(64)]
    [InlineData(200)]
    public void ATooltipLongerThanWindowsAllowsIsRejected(int length)
    {
        RequireWindows();

        // NotifyIcon.Text throws past 63 characters rather than truncating, so
        // the tray host clips it. This pins the limit the clipping is built on
        // instead of trusting a number in a comment.
        Wpf.Run(() =>
        {
            using var icon = new System.Windows.Forms.NotifyIcon();
            var text = new string('x', length);

            if (length <= 63)
            {
                icon.Text = text;
                Assert.Equal(text, icon.Text);
            }
            else
            {
                Assert.ThrowsAny<ArgumentException>(() => icon.Text = text);
            }
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
}
