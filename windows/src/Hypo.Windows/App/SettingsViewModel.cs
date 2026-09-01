using Hypo.Core.Abstractions;
using Hypo.Core.History;
using Hypo.Core.Pairing;
using Hypo.Core.Transport;

namespace Hypo.Windows.App;

/// <summary>One paired device, as Settings shows it.</summary>
public sealed record DeviceRow
{
    public required PairedDevices.Device Device { get; init; }

    /// <summary>Whether it is reachable on this network right now.</summary>
    public required bool OnLan { get; init; }

    public string DisplayName => Device.DisplayName;

    public string DeviceId => Device.DeviceId;

    /// <summary>
    /// "On this network" or "Not on this network".
    ///
    /// <para>Deliberately not "offline": a phone that is out of the house is
    /// still paired and still reachable through the relay, and calling that
    /// offline would send someone looking for a fault that is not there.</para>
    /// </summary>
    public string Status => OnLan ? "On this network" : "Not on this network";
}

/// <summary>
/// Everything the settings window shows and does, with no window involved.
///
/// <para>The window is a list of controls bound to this. Every decision --
/// what a device row says, what happens when the retention limit changes, what
/// the status line reads -- is here, where it can be tested on any machine.</para>
/// </summary>
public sealed class SettingsViewModel
{
    private readonly ISecretStore _store;
    private readonly ClipboardHistoryStore _history;
    private readonly ISyncStatusSource _status;
    private readonly Action<HypoSettings> _save;
    private readonly Func<bool> _readStartup;
    private readonly Func<bool, string?> _writeStartup;

    /// <param name="readStartup">Whether Hypo currently starts with Windows.</param>
    /// <param name="writeStartup">Turns that on or off; returns why not, or null.</param>
    public SettingsViewModel(
        ISecretStore store,
        ClipboardHistoryStore history,
        ISyncStatusSource status,
        HypoSettings settings,
        Action<HypoSettings> save,
        Func<bool> readStartup,
        Func<bool, string?> writeStartup)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(history);
        ArgumentNullException.ThrowIfNull(status);
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(save);
        ArgumentNullException.ThrowIfNull(readStartup);
        ArgumentNullException.ThrowIfNull(writeStartup);

        _store = store;
        _history = history;
        _status = status;
        _save = save;
        _readStartup = readStartup;
        _writeStartup = writeStartup;

        Settings = settings;
        _history.Capacity = settings.HistoryLimit;
    }

    public HypoSettings Settings { get; private set; }

    /// <summary>Paired devices, with whichever are on this network marked.</summary>
    public IReadOnlyList<DeviceRow> Devices { get; private set; } = [];

    /// <summary>Why something did not work, or null. Shown as written.</summary>
    public string? LastMessage { get; private set; }

    /// <summary>Whether Hypo starts with Windows.</summary>
    public bool RunsAtLogin => _readStartup();

    /// <summary>
    /// One line describing the connection, in the words the tray icon uses.
    /// </summary>
    public string ConnectionSummary => _status.State switch
    {
        TransportState.Connected when _status.LanPeers.Count > 0 =>
            $"Connected — {_status.LanPeers.Count} device{(_status.LanPeers.Count == 1 ? "" : "s")} on this network",
        TransportState.Connected => "Connected through the relay",
        TransportState.Connecting => "Connecting…",
        _ => "Not connected",
    };

    /// <summary>
    /// Takes settings changed somewhere else -- the tray menu carries three of
    /// the same switches.
    ///
    /// <para>Does not save: whoever changed them already did. Saving here would
    /// be a second writer for one setting, which is the thing this exists to
    /// avoid.</para>
    /// </summary>
    public void Adopt(HypoSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        Settings = settings;
        _history.Capacity = settings.HistoryLimit;
    }

    public void Refresh()
    {
        var onLan = _status.LanPeers.ToHashSet(StringComparer.OrdinalIgnoreCase);

        Devices = PairedDevices.All(_store)
            .Select(device => new DeviceRow { Device = device, OnLan = onLan.Contains(device.DeviceId) })
            .ToArray();
    }

    /// <summary>
    /// Unpairs a device.
    ///
    /// <para>Says what it did in <see cref="LastMessage"/> rather than silently
    /// removing a row: this cannot be undone from here -- the two devices have
    /// to be introduced again -- so it should be visibly deliberate.</para>
    /// </summary>
    public void Unpair(DeviceRow row)
    {
        ArgumentNullException.ThrowIfNull(row);

        LastMessage = PairedDevices.Forget(_store, row.DeviceId)
            ? $"Unpaired {row.DisplayName}. To sync with it again, pair the two devices."
            : $"{row.DisplayName} was not paired.";

        Refresh();
    }

    /// <summary>
    /// Changes how many entries are kept, applying it now.
    /// </summary>
    public void SetHistoryLimit(int limit)
    {
        if (limit < HypoSettings.MinimumHistoryLimit || limit > HypoSettings.MaximumHistoryLimit)
        {
            LastMessage =
                $"Keep between {HypoSettings.MinimumHistoryLimit} and {HypoSettings.MaximumHistoryLimit} entries.";
            return;
        }

        var before = _history.Recent(HypoSettings.MaximumHistoryLimit).Count;

        _history.Capacity = limit;
        Update(Settings with { HistoryLimit = limit });

        var after = _history.Recent(HypoSettings.MaximumHistoryLimit).Count;

        LastMessage = after < before
            ? $"Keeping {limit} entries. {before - after} older {(before - after == 1 ? "entry was" : "entries were")} removed."
            : $"Keeping {limit} entries.";
    }

    public void ClearHistory()
    {
        var count = _history.Recent(HypoSettings.MaximumHistoryLimit).Count;

        _history.Clear();

        LastMessage = count == 0
            ? "There was nothing to clear."
            : $"Cleared {count} {(count == 1 ? "entry" : "entries")}.";
    }

    /// <summary>
    /// Turns starting with Windows on or off.
    ///
    /// <para>The switch reflects what the registry actually says afterwards, not
    /// what was asked for. On a machine where policy locks that key, a switch
    /// that stayed where it was put would be a lie.</para>
    /// </summary>
    public void SetRunAtLogin(bool enabled)
    {
        LastMessage = _writeStartup(enabled)
            ?? (enabled
                ? "Hypo will start when you sign in."
                : "Hypo will not start on its own.");
    }

    /// <summary>
    /// Whether a transport or port change is waiting for a restart.
    ///
    /// <para>These three are read once, when the client is built. Saying so is
    /// the alternative to either lying about when the change takes effect or
    /// tearing down and rebuilding both transports underneath a running
    /// application.</para>
    /// </summary>
    public bool NeedsRestart { get; private set; }

    /// <summary>
    /// Renames this device, returning the name that was actually kept.
    ///
    /// <para>Blank input is refused, so a cleared field snaps back rather than
    /// appearing to have been taken. Peers already paired keep the name they
    /// stored at pairing time; this reaches the network when the device next
    /// advertises.</para>
    /// </summary>
    public string SetDeviceName(string? name)
    {
        var sanitised = HypoSettings.SanitiseDeviceName(name);
        if (sanitised is null || sanitised == Settings.EffectiveDeviceName)
        {
            return Settings.EffectiveDeviceName;
        }

        Settings = Settings with { DeviceName = sanitised };
        _save(Settings);

        return sanitised;
    }

    public void SetLanEnabled(bool enabled) => UpdateTransport(Settings with { LanEnabled = enabled });

    public void SetCloudEnabled(bool enabled) => UpdateTransport(Settings with { CloudEnabled = enabled });

    /// <summary>
    /// Changes the port the LAN listener binds.
    ///
    /// <para>Zero is allowed and means "ask Windows for a free one", which is
    /// the answer when something else already holds the default. Below 1024 is
    /// refused: those need administrator rights on Windows, so the application
    /// would simply fail to bind.</para>
    /// </summary>
    public void SetLanPort(int port)
    {
        if (port != 0 && port is < 1024 or > 65535)
        {
            LastMessage = "Use a port between 1024 and 65535, or 0 to let Windows choose one.";
            return;
        }

        UpdateTransport(Settings with { LanPort = port });
    }

    private void UpdateTransport(HypoSettings settings)
    {
        var changed = settings.LanEnabled != Settings.LanEnabled
            || settings.CloudEnabled != Settings.CloudEnabled
            || settings.LanPort != Settings.LanPort;

        Update(settings);

        if (!changed)
        {
            return;
        }

        NeedsRestart = true;
        LastMessage = settings is { LanEnabled: false, CloudEnabled: false }
            ? "Saved. Both are off, so nothing will sync until one is back on. Restart Hypo to apply."
            : "Saved. Restart Hypo to apply.";
    }

    public void SetShareWithWindowsHistory(bool enabled) =>
        Update(Settings with { ShareWithWindowsHistory = enabled });

    public void SetAllowCloudClipboardUpload(bool enabled) =>
        Update(Settings with { AllowCloudClipboardUpload = enabled });

    public void SetNotifyOnArrival(bool enabled) =>
        Update(Settings with { NotifyOnArrival = enabled });

    private void Update(HypoSettings settings)
    {
        Settings = settings;
        _save(settings);
    }
}
