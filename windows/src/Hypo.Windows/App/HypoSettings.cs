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
