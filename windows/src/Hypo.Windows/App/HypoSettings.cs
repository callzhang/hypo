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

    private static readonly JsonSerializerOptions Format = new() { WriteIndented = true };

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
                ? JsonSerializer.Deserialize<HypoSettings>(File.ReadAllText(path)) ?? new HypoSettings()
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
