using Hypo.Core.History;

namespace Hypo.Windows.App;

/// <summary>
/// What to say when something arrives from another device.
///
/// <para>Without a notification, a copy made on the phone reaches this machine
/// silently and the only way to know is to paste and see. The design asks for
/// one, with a preview, and only for remote arrivals: notifying someone about
/// the thing they just copied themselves is noise.</para>
///
/// <para>Separate from the tray icon so the wording, the truncation and the
/// local-echo rule are testable on any machine.</para>
/// </summary>
public sealed record ArrivalNotice
{
    /// <summary>What a balloon title will take before Windows truncates it.</summary>
    public const int MaxTitle = 63;

    /// <summary>What a balloon body will take.</summary>
    public const int MaxBody = 255;

    /// <summary>
    /// How much of the content to show.
    ///
    /// <para>Far below the limit on purpose. This is enough to recognise what
    /// arrived and not enough to read a password over someone's shoulder, which
    /// is a real risk for content that came from a phone's password manager --
    /// the same reasoning as the two clipboard sharing settings.</para>
    /// </summary>
    public const int MaxPreview = 80;

    public required string Title { get; init; }

    public required string Body { get; init; }

    /// <summary>
    /// The notice for an entry, or null when there is nothing worth saying.
    /// </summary>
    public static ArrivalNotice? For(HistoryEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);

        // Copied here. The person who copied it knows.
        if (entry.SourceDeviceId is null && entry.SourceDeviceName is null)
        {
            return null;
        }

        var device = entry.SourceDeviceName ?? entry.SourceDeviceId!;

        return new ArrivalNotice
        {
            Title = Fit($"Copied from {device}", MaxTitle),
            Body = Fit(Preview(entry), MaxBody),
        };
    }

    private static string Preview(HistoryEntry entry)
    {
        var described = HistoryViewModel.Describe(entry.Content);

        return Fit(described, MaxPreview);
    }

    /// <summary>
    /// Shortens with an ellipsis. Windows throws rather than truncating when a
    /// balloon's text is too long, so this cannot be left to it.
    /// </summary>
    private static string Fit(string text, int limit) =>
        text.Length <= limit ? text : string.Concat(text.AsSpan(0, limit - 1), "…");
}
