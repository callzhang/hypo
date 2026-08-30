using System.Globalization;
using System.Text;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;

namespace Hypo.Windows.App;

/// <summary>One row in the history list, ready to display.</summary>
public sealed record HistoryRow
{
    public required ClipboardContent Content { get; init; }

    public required string Preview { get; init; }

    public required DateTimeOffset CopiedAt { get; init; }

    /// <summary>Where it came from, or "This PC" when it was copied here.</summary>
    public required string Source { get; init; }

    public ContentType ContentType => Content.ContentType;
}

/// <summary>
/// The history window's contents and behaviour, with no window involved.
///
/// <para>Filtering, previews and putting an entry back are where this can be
/// wrong, and none of them need a UI to decide. Keeping them here is what makes
/// them testable on a machine that cannot run the application at all.</para>
/// </summary>
public sealed class HistoryViewModel(ClipboardHistoryStore history, IClipboard clipboard)
{
    private readonly ClipboardHistoryStore _history =
        history ?? throw new ArgumentNullException(nameof(history));

    private readonly IClipboard _clipboard =
        clipboard ?? throw new ArgumentNullException(nameof(clipboard));

    private IReadOnlyList<HistoryRow> _all = [];

    public IReadOnlyList<HistoryRow> Rows { get; private set; } = [];

    public string Filter { get; private set; } = string.Empty;

    /// <summary>True when there is nothing to show. A state, not an error.</summary>
    public bool IsEmpty => Rows.Count == 0;

    public void Refresh(int limit = 200)
    {
        _all = _history.Recent(limit).Select(ToRow).ToArray();
        Apply();
    }

    public void SetFilter(string? filter)
    {
        Filter = filter?.Trim() ?? string.Empty;
        Apply();
    }

    /// <summary>
    /// Puts an entry back on the clipboard.
    ///
    /// <para>It goes through <see cref="IClipboard"/>, which promises not to
    /// republish its own writes. That is load-bearing: without it, choosing an
    /// old entry would look like a fresh local copy and be sent to every peer,
    /// so browsing history would spam the user's other devices.</para>
    /// </summary>
    public Task UseAsync(HistoryRow row, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(row);
        return _clipboard.SetAsync(row.Content, ct);
    }

    private void Apply() =>
        Rows = Filter.Length == 0
            ? _all
            : _all.Where(Matches).ToArray();

    /// <summary>
    /// Matches the preview rather than the raw bytes.
    ///
    /// <para>Searching the content would never match an image, and would match a
    /// file only if the query happened to appear inside it. The preview is what
    /// the user is looking at, so it is what they are searching.</para>
    /// </summary>
    private bool Matches(HistoryRow row) =>
        row.Preview.Contains(Filter, StringComparison.CurrentCultureIgnoreCase)
        || row.Source.Contains(Filter, StringComparison.CurrentCultureIgnoreCase);

    private static HistoryRow ToRow(HistoryEntry entry) => new()
    {
        Content = entry.Content,
        Preview = Describe(entry.Content),
        CopiedAt = entry.CopiedAt,
        Source = entry.SourceDeviceName ?? entry.SourceDeviceId ?? "This PC",
    };

    /// <summary>A one-line description suited to the content type.</summary>
    public static string Describe(ClipboardContent content)
    {
        ArgumentNullException.ThrowIfNull(content);

        return content.ContentType switch
        {
            ContentType.Text or ContentType.Link => OneLine(Encoding.UTF8.GetString(content.Data)),
            ContentType.File => content.FileName ?? "File",
            ContentType.Image => $"Image, {Size(content.Data.Length)}",
            _ => $"{content.ContentType}, {Size(content.Data.Length)}",
        };
    }

    /// <summary>
    /// Collapses whitespace so a multi-line copy does not take over the list.
    /// A pasted stack trace is one row like anything else.
    /// </summary>
    private static string OneLine(string text)
    {
        var collapsed = string.Join(' ', text.Split(
            (char[])['\r', '\n', '\t'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));

        return collapsed.Length == 0 ? "(blank)" : collapsed;
    }

    private static string Size(int bytes) => bytes switch
    {
        < 1024 => $"{bytes} bytes",
        < 1024 * 1024 => $"{bytes / 1024.0:0.#} KB".ToString(CultureInfo.CurrentCulture),
        _ => $"{bytes / (1024.0 * 1024.0):0.#} MB".ToString(CultureInfo.CurrentCulture),
    };
}
