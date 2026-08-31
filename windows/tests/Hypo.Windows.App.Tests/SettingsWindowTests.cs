using System.IO;
using System.Text;
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
/// The settings window, opened for real.
///
/// <para>What every control means is <see cref="SettingsViewModel"/>'s and is
/// tested there. This is about the window: that the controls exist, show the
/// right thing, and are wired to the model.</para>
/// </summary>
[Collection("wpf")]
public class SettingsWindowTests : IDisposable
{
    private const string PhoneId = "bbe296d6-0785-43d2-91b6-b135b72f4c41";

    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-settings-window").FullName;
    private readonly ClipboardHistoryStore _history;
    private readonly InMemorySecretStore _store = new();
    private readonly Status _status = new();
    private readonly List<HypoSettings> _saved = [];

    private bool _startsAtLogin;

    public SettingsWindowTests()
    {
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));

        _store.Write(PhoneId, new byte[32]);
        PairedDevices.Remember(_store, PhoneId, "OPPO PLP110");

        for (var i = 0; i < 12; i++)
        {
            _history.Add(new HistoryEntry
            {
                Content = new ClipboardContent
                {
                    ContentType = ContentType.Text,
                    Data = Encoding.UTF8.GetBytes($"entry {i}"),
                },
                CopiedAt = DateTimeOffset.UnixEpoch.AddMinutes(i),
            });
        }
    }

    public void Dispose()
    {
        _history.Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    private sealed class Status : ISyncStatusSource
    {
        public IReadOnlyCollection<string> LanPeers { get; set; } = [];

        public TransportState State { get; set; } = TransportState.Connected;
    }

    private SettingsWindow Open(HypoSettings? settings = null, string? hotkey = null)
    {
        var model = new SettingsViewModel(
            _store,
            _history,
            _status,
            settings ?? new HypoSettings(),
            _saved.Add,
            () => _startsAtLogin,
            enabled => { _startsAtLogin = enabled; return null; });

        var window = new SettingsWindow(model) { HotkeyStatus = hotkey };
        window.Bind();
        window.Show();
        window.Settle();

        return window;
    }

    private static void Click(SettingsWindow window, string name) =>
        ((System.Windows.Controls.Button)window.FindName(name)).RaiseEvent(
            new System.Windows.RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));

    [SkippableFact]
    public void ShowsThePairedDevicesAndTheConnection()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        _status.LanPeers = [PhoneId];

        Wpf.Run(() =>
        {
            var window = Open();

            var devices = (System.Windows.Controls.ListBox)window.FindName("Devices");
            var row = Assert.IsType<DeviceRow>(Assert.Single(devices.Items));

            Assert.Equal("OPPO PLP110", row.DisplayName);
            Assert.Equal("Connected — 1 device on this network",
                ((System.Windows.Controls.TextBlock)window.FindName("Connection")).Text);

            window.Capture("settings-window");
            window.Close();
        });
    }

    [SkippableFact]
    public void UnpairingRemovesTheDeviceAndSaysWhatHappened()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();
            var devices = (System.Windows.Controls.ListBox)window.FindName("Devices");

            // Through the window's own method: the click handler asks a modal
            // question first, and a test cannot answer it.
            window.Unpair((DeviceRow)devices.Items[0]!);
            window.Settle();

            Assert.Empty(devices.Items);
            Assert.Null(_store.Read(PhoneId));
            Assert.Contains("Unpaired OPPO PLP110", ((System.Windows.Controls.TextBlock)window.FindName("Message")).Text);

            window.Close();
        });
    }

    [SkippableFact]
    public void UnpairWithNothingChosenSaysSoRatherThanDoingNothing()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            Click(window, "UnpairButton");
            window.Settle();

            Assert.Equal("Choose a device first.", ((System.Windows.Controls.TextBlock)window.FindName("Message")).Text);
            Assert.NotNull(_store.Read(PhoneId));

            window.Close();
        });
    }

    [SkippableFact]
    public void ChangingTheRetentionLimitPrunesAndSaves()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            ((System.Windows.Controls.TextBox)window.FindName("LimitBox")).Text = "10";
            Click(window, "ApplyLimitButton");
            window.Settle();

            Assert.Equal(10, _history.Recent(2000).Count);
            Assert.Equal(10, _saved[^1].HistoryLimit);
            Assert.Contains("2 older entries were removed", ((System.Windows.Controls.TextBlock)window.FindName("Message")).Text);

            window.Close();
        });
    }

    [SkippableFact]
    public void SomethingThatIsNotANumberIsRefusedWithoutTouchingTheHistory()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            ((System.Windows.Controls.TextBox)window.FindName("LimitBox")).Text = "as many as possible";
            Click(window, "ApplyLimitButton");
            window.Settle();

            Assert.Equal(12, _history.Recent(2000).Count);
            Assert.Empty(_saved);
            Assert.Contains("not a number", ((System.Windows.Controls.TextBlock)window.FindName("Message")).Text);

            window.Close();
        });
    }

    [SkippableFact]
    public void ClearingEmptiesTheHistory()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            Click(window, "ClearButton");
            window.Settle();

            Assert.Empty(_history.Recent());
            Assert.Equal("Cleared 12 entries.", ((System.Windows.Controls.TextBlock)window.FindName("Message")).Text);

            window.Close();
        });
    }

    [SkippableFact]
    public void TheSwitchesShowWhatIsSavedAndWriteWhatIsClicked()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open(new HypoSettings { ShareWithWindowsHistory = true });

            Assert.True(((System.Windows.Controls.CheckBox)window.FindName("WindowsHistoryBox")).IsChecked);
            Assert.False(((System.Windows.Controls.CheckBox)window.FindName("CloudBox")).IsChecked);
            Assert.True(((System.Windows.Controls.CheckBox)window.FindName("NotifyBox")).IsChecked);

            var cloud = (System.Windows.Controls.CheckBox)window.FindName("CloudBox");
            cloud.IsChecked = true;
            cloud.RaiseEvent(new System.Windows.RoutedEventArgs(
                System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.Settle();

            Assert.True(_saved[^1].AllowCloudClipboardUpload);

            window.Close();
        });
    }

    [SkippableFact]
    public void StartingWithWindowsIsASwitchThatSticks()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();
            var box = (System.Windows.Controls.CheckBox)window.FindName("StartupBox");

            Assert.False(box.IsChecked);

            box.IsChecked = true;
            box.RaiseEvent(new System.Windows.RoutedEventArgs(
                System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.Settle();

            Assert.True(_startsAtLogin);
            Assert.True(box.IsChecked);
            Assert.Contains("when you sign in", ((System.Windows.Controls.TextBlock)window.FindName("Message")).Text);

            window.Close();
        });
    }

    [SkippableFact]
    public void AFailedShortcutIsExplainedHere()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // The design puts a failed registration in Settings, and this is the
        // only place with room to say what to do instead.
        Wpf.Run(() =>
        {
            var window = Open(hotkey: "Shortcut: Alt+V is already taken by another application.");

            var shortcut = (System.Windows.Controls.TextBlock)window.FindName("Shortcut");

            Assert.Equal(System.Windows.Visibility.Visible, shortcut.Visibility);
            Assert.Contains("already taken", shortcut.Text);

            window.Capture("settings-window-shortcut-taken");
            window.Close();
        });
    }

    [SkippableFact]
    public void WithNothingToSayAboutTheShortcutTheLineIsNotThere()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            Assert.Equal(
                System.Windows.Visibility.Collapsed,
                ((System.Windows.Controls.TextBlock)window.FindName("Shortcut")).Visibility);

            window.Close();
        });
    }
}
