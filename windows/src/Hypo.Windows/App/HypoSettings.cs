using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hypo.Windows.App;

/// <summary>
/// The handful of choices the user gets, and where they are kept.
///
/// <para>Both sharing settings default to off. That is a deliberate posture
/// rather than caution: Hypo puts whatever was copied on another device onto
/// this clipboard, and a password from a phone's password manager roaming to a
/// Microsoft account is worse than the convenience of Win+V is good. Opting in
/// is one click; opting out after the fact does not un-upload anything.</para>
/// </summary>
public sealed record HypoSettings
{
    /// <summary>
    /// Whether the first-run note about the Windows Firewall prompt has been
    /// shown.
    ///
    /// <para>Binding a LAN port makes Windows ask which networks to allow, and
    /// the answer decides whether local sync works at all. Someone who dismisses
    /// it, or picks "Public networks" on a home Wi-Fi, gets a client that only
    /// ever uses the relay and no indication why -- so it is worth one sentence
    /// beforehand, exactly once.</para>
    /// </summary>
    public bool FirewallNoticeShown { get; init; }

    /// <summary>
    /// The key combination that opens the history, written the way it reads:
    /// "Alt+V".
    ///
    /// <para>Text rather than an enum pair so the file stays legible to whoever
    /// opens it, and an unparseable value falls back to the default rather than
    /// stopping the application.</para>
    /// </summary>
    public string Hotkey { get; init; } = HotkeyBinding.Default.ToString();

    [JsonIgnore]
    public HotkeyBinding HotkeyBinding => HotkeyBinding.Parse(Hotkey) ?? HotkeyBinding.Default;

    /// <summary>
    /// Whether to sync over the local network.
    ///
    /// <para>On by default and worth keeping on: it is faster and the content
    /// never leaves the building. Someone on a network that blocks the
    /// discovery, or who would rather not advertise the machine, can turn it
    /// off and use the relay alone.</para>
    /// </summary>
    /// <summary>
    /// What peers call this device. Blank means the machine name.
    ///
    /// <para>Stored rather than always taken from <see cref="Environment.MachineName"/>
    /// because that is what the OS calls the machine, which is rarely what its
    /// owner would call it -- and it is the name every peer shows.</para>
    /// </summary>
    public string DeviceName { get; init; } = string.Empty;

    /// <summary>The name to advertise and send: the stored one, or the machine's.</summary>
    public string EffectiveDeviceName =>
        string.IsNullOrWhiteSpace(DeviceName) ? Environment.MachineName : DeviceName;

    /// <summary>
    /// Sanitises a name the way every other client does: trimmed, without a
    /// <c>.local</c> suffix. Returns null when nothing usable is left, since a
    /// device with no name is worse than one named after the machine.
    /// </summary>
    public static string? SanitiseDeviceName(string? name)
    {
        var sanitised = (name ?? string.Empty).Replace(".local", string.Empty, StringComparison.OrdinalIgnoreCase).Trim();

        return sanitised.Length == 0 ? null : sanitised;
    }

    public bool LanEnabled { get; init; } = true;

    /// <summary>
    /// Whether to sync through the relay when the LAN cannot reach a peer.
    ///
    /// <para>Off means devices on different networks stop syncing entirely. The
    /// content is encrypted end to end either way, so this is about whether it
    /// leaves the network at all.</para>
    /// </summary>
    public bool CloudEnabled { get; init; } = true;

    /// <summary>The port the LAN listener binds. 0 asks Windows for a free one.</summary>
    public int LanPort { get; init; } = DefaultLanPort;

    public const int DefaultLanPort = 7010;

    /// <summary>How many entries the history keeps. The design's number.</summary>
    public int HistoryLimit { get; init; } = DefaultHistoryLimit;

    public const int DefaultHistoryLimit = 200;

    /// <summary>
    /// Below this the history stops being a history.
    ///
    /// <para>Ten is enough to be useful and small enough to be a real answer for
    /// someone who wants very little of their clipboard on disk. Zero is not
    /// offered: that is what turning sync off is for, and a history of nothing
    /// looks like a broken window.</para>
    /// </summary>
    public const int MinimumHistoryLimit = 10;

    /// <summary>
    /// Above this the window is slower to open than the thing it saves.
    /// </summary>
    public const int MaximumHistoryLimit = 2000;

    /// <summary>
    /// Whether an arrival from another device raises a notification.
    ///
    /// <para>On by default, unlike the two sharing switches: a copy that reaches
    /// this machine silently is one you find out about by pasting and seeing,
    /// and this one shares nothing outside the screen already in front of
    /// you.</para>
    /// </summary>
    public bool NotifyOnArrival { get; init; } = true;

    /// <summary>Whether synced items may appear in this machine's Win+V history.</summary>
    public bool ShareWithWindowsHistory { get; init; }

    /// <summary>
    /// Whether Windows may upload synced items to the user's cloud clipboard,
    /// which roams them to a Microsoft account and every machine signed into it.
    /// </summary>
    public bool AllowCloudClipboardUpload { get; init; }

    [JsonIgnore]
    public Clipboard.ClipboardPrivacy Privacy => new()
    {
        AllowLocalHistory = ShareWithWindowsHistory,
        AllowCloudUpload = AllowCloudClipboardUpload,
    };

    // Indented and case-insensitive because this file is meant to be opened and
    // edited by hand, and "hotkey" should not quietly mean nothing.
    private static readonly JsonSerializerOptions Format = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
    };

    /// <summary>
    /// Reads the settings, falling back to the defaults for anything missing.
    ///
    /// <para>A corrupt or unreadable file yields the defaults rather than an
    /// error. The defaults are the safe end of both switches, so failing this
    /// way cannot silently widen what is shared -- which is the only failure
    /// mode here that would matter.</para>
    /// </summary>
    public static HypoSettings Load(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);

        try
        {
            return File.Exists(path)
                ? JsonSerializer.Deserialize<HypoSettings>(File.ReadAllText(path), Format) ?? new HypoSettings()
                : new HypoSettings();
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return new HypoSettings();
        }
    }

    public void Save(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);

        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, Format));
    }

    public static string PathIn(string stateDirectory) =>
        Path.Combine(stateDirectory, "settings.json");
}
