using System.Runtime.Versioning;

namespace Hypo.Windows.Clipboard;

/// <summary>
/// How far a clipboard item is allowed to travel once it is on this machine.
///
/// <para>Windows shares clipboard content in two directions that have nothing
/// to do with this application: the local Win+V history, and the cloud clipboard
/// that roams to a Microsoft account and every other machine signed into it. A
/// writer opts out by publishing marker formats alongside the content.</para>
///
/// <para>Both default to opting out, which is the design's decision and worth
/// restating: Hypo carries whatever the user copied on their phone, and a
/// password from a phone's password manager silently roaming to a Microsoft
/// account is a considerably worse outcome than the convenience is worth. Both
/// are opt-in, and the cloud one says what it means in the interface.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public sealed record ClipboardPrivacy
{
    /// <summary>
    /// Its presence on the clipboard excludes the item from the Win+V history,
    /// whatever the data is. Windows checks for the format, not its value.
    /// </summary>
    /// <remarks>
    /// Resolved lazily. As a static initialiser it would run on the first touch
    /// of this type anywhere, including from the policy tests, and calling
    /// user32 off Windows fails -- so the decision about what to restrict could
    /// only be tested on the one platform that needs it least.
    /// </remarks>
    public static uint ExcludeFromHistoryFormat => ExcludeFromHistory.Value;

    private static readonly Lazy<uint> ExcludeFromHistory =
        new(() => NativeMethods.RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing"));

    /// <summary>
    /// A DWORD: zero forbids the upload, non-zero permits it. Unlike the history
    /// marker this one carries a value, so omitting it entirely is not the same
    /// as forbidding.
    /// </summary>
    public static uint CanUploadToCloudFormat => CanUploadToCloud.Value;

    private static readonly Lazy<uint> CanUploadToCloud =
        new(() => NativeMethods.RegisterClipboardFormat("CanUploadToCloudClipboard"));

    /// <summary>Whether the item may appear in this machine's Win+V history.</summary>
    public bool AllowLocalHistory { get; init; }

    /// <summary>Whether Windows may upload it to the user's cloud clipboard.</summary>
    public bool AllowCloudUpload { get; init; }

    /// <summary>The defaults: neither.</summary>
    public static ClipboardPrivacy Private { get; } = new();

    /// <summary>
    /// Whether a marker excluding the item from Win+V should be published.
    /// </summary>
    /// <remarks>
    /// Separate from <see cref="Markers"/> so the policy can be tested anywhere.
    /// Reading a format id calls into user32, so anything touching one is a
    /// Windows-only test -- and the decision about what to restrict is the part
    /// worth checking on every machine.
    /// </remarks>
    public bool RestrictsLocalHistory => !AllowLocalHistory;

    /// <summary>Whether a marker forbidding the cloud upload should be published.</summary>
    public bool RestrictsCloudUpload => !AllowCloudUpload;

    /// <summary>How many markers this policy publishes.</summary>
    public int MarkerCount => (RestrictsLocalHistory ? 1 : 0) + (RestrictsCloudUpload ? 1 : 0);

    /// <summary>The value the cloud marker carries: a DWORD zero.</summary>
    public static byte[] ForbidCloudUploadValue => BitConverter.GetBytes(0u);

    /// <summary>
    /// The marker formats to publish alongside the content.
    ///
    /// <para>Only the ones that restrict are written. Publishing
    /// <c>CanUploadToCloudClipboard = 1</c> when the user has allowed it is
    /// redundant -- absence already means "no opinion" -- and asserting a
    /// permission we were not asked to assert is the wrong default for a
    /// clipboard tool.</para>
    /// </summary>
    public IReadOnlyList<(uint Format, byte[] Data)> Markers()
    {
        var markers = new List<(uint, byte[])>(2);

        if (RestrictsLocalHistory)
        {
            // The value is ignored; one byte is the conventional payload.
            markers.Add((ExcludeFromHistoryFormat, [0]));
        }

        if (RestrictsCloudUpload)
        {
            markers.Add((CanUploadToCloudFormat, ForbidCloudUploadValue));
        }

        return markers;
    }
}
