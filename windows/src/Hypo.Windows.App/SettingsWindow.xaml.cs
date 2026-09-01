using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using Hypo.Windows.App;

namespace Hypo.Windows.App.Shell;

/// <summary>
/// Shows <see cref="SettingsViewModel"/>.
///
/// <para>An ordinary window, in the taskbar, unlike the history popup: this is
/// somewhere you go and stay for a minute, not something a keystroke throws on
/// screen.</para>
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly SettingsViewModel _model;
    private readonly Action _openPairing;

    public SettingsWindow(SettingsViewModel model, Action? openPairing = null)
    {
        _model = model;
        _openPairing = openPairing ?? (() => { });

        InitializeComponent();

        SourceInitialized += (_, _) => ThemeHost.Register(this);
        Bind();
    }

    /// <summary>
    /// What the shortcut is, or why it is not working.
    ///
    /// <para>The design puts a failed registration here, and this is the only
    /// place with room to explain it.</para>
    /// </summary>
    public string? HotkeyStatus { get; set; }

    /// <summary>
    /// Re-reads everything after settings changed somewhere else.
    ///
    /// <para>Rebinding alone was not enough: the model held the settings it was
    /// built with, so the window redrew the same stale values.</para>
    /// </summary>
    public void Adopt(HypoSettings settings)
    {
        _model.Adopt(settings);
        Bind();
    }

    public void Bind()
    {
        _model.Refresh();

        Connection.Text = _model.ConnectionSummary;
        Devices.ItemsSource = _model.Devices;

        LimitBox.Text = _model.Settings.HistoryLimit.ToString(CultureInfo.CurrentCulture);
        PortBox.Text = _model.Settings.LanPort.ToString(CultureInfo.CurrentCulture);
        LanBox.IsChecked = _model.Settings.LanEnabled;
        CloudBox2.IsChecked = _model.Settings.CloudEnabled;
        RestartNotice.Visibility = _model.NeedsRestart ? Visibility.Visible : Visibility.Collapsed;
        StartupBox.IsChecked = _model.RunsAtLogin;
        NotifyBox.IsChecked = _model.Settings.NotifyOnArrival;
        WindowsHistoryBox.IsChecked = _model.Settings.ShareWithWindowsHistory;
        CloudBox.IsChecked = _model.Settings.AllowCloudClipboardUpload;

        Shortcut.Text = HotkeyStatus ?? string.Empty;
        Shortcut.Visibility = string.IsNullOrEmpty(Shortcut.Text)
            ? Visibility.Collapsed
            : Visibility.Visible;

        Message.Text = _model.LastMessage ?? string.Empty;
        UnpairButton.IsEnabled = Devices.SelectedItem is not null;
    }

    private void OnPair(object sender, RoutedEventArgs e) => _openPairing();

    /// <summary>
    /// Enables Unpair once there is something to unpair.
    ///
    /// <para>Without this the button is disabled from the moment the window
    /// binds and never comes back, because nothing is selected then. Raising a
    /// click in a test goes through whatever IsEnabled says, so the tests were
    /// happy and the button was dead.</para>
    /// </summary>
    private void OnDeviceSelected(object sender, SelectionChangedEventArgs e) =>
        UnpairButton.IsEnabled = Devices.SelectedItem is not null;

    private void OnUnpair(object sender, RoutedEventArgs e)
    {
        if (Devices.SelectedItem is not DeviceRow row)
        {
            Message.Text = "Choose a device first.";
            return;
        }

        // Unpairing cannot be undone from here: the two devices have to be
        // introduced again. Worth one question.
        var confirmed = System.Windows.MessageBox.Show(
            $"Stop syncing with {row.DisplayName}?\n\nTo sync with it again you will have to pair the two devices.",
            "Hypo",
            System.Windows.MessageBoxButton.OKCancel,
            System.Windows.MessageBoxImage.Question);

        if (confirmed is not System.Windows.MessageBoxResult.OK)
        {
            return;
        }

        Unpair(row);
    }

    /// <summary>Unpairs without asking. The confirmation lives in the click handler.</summary>
    public void Unpair(DeviceRow row)
    {
        _model.Unpair(row);
        Bind();
    }

    private void OnApplyLimit(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(LimitBox.Text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var limit))
        {
            Message.Text = $"That is not a number. Keep between "
                + $"{HypoSettings.MinimumHistoryLimit} and {HypoSettings.MaximumHistoryLimit} entries.";
            return;
        }

        _model.SetHistoryLimit(limit);
        Bind();
    }

    private void OnLanChanged(object sender, RoutedEventArgs e)
    {
        _model.SetLanEnabled(LanBox.IsChecked == true);
        Bind();
    }

    private void OnCloudTransportChanged(object sender, RoutedEventArgs e)
    {
        _model.SetCloudEnabled(CloudBox2.IsChecked == true);
        Bind();
    }

    private void OnApplyPort(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(PortBox.Text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var port))
        {
            Message.Text = "That is not a number. Use a port between 1024 and 65535, or 0 to let Windows choose one.";
            return;
        }

        _model.SetLanPort(port);
        Bind();
    }

    private void OnClear(object sender, RoutedEventArgs e)
    {
        _model.ClearHistory();
        Bind();
    }

    private void OnStartupChanged(object sender, RoutedEventArgs e)
    {
        _model.SetRunAtLogin(StartupBox.IsChecked == true);
        Bind();
    }

    private void OnNotifyChanged(object sender, RoutedEventArgs e)
    {
        _model.SetNotifyOnArrival(NotifyBox.IsChecked == true);
        Bind();
    }

    private void OnWindowsHistoryChanged(object sender, RoutedEventArgs e)
    {
        _model.SetShareWithWindowsHistory(WindowsHistoryBox.IsChecked == true);
        Bind();
    }

    private void OnCloudChanged(object sender, RoutedEventArgs e)
    {
        _model.SetAllowCloudClipboardUpload(CloudBox.IsChecked == true);
        Bind();
    }
}
