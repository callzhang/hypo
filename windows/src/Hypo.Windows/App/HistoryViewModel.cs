using System.Globalization;
using System.Text;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Core.Transport;

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

    /// <summary>Which channel carried it, or null when it was copied here.</summary>
    public TransportOrigin? Origin { get; init; }

    public bool Pinned { get; init; }

    /// <summary>
    /// A glyph for the content type, from the font every Windows 10 and 11
    /// machine has.
    ///
    /// <para>Segoe MDL2 rather than the newer Segoe Fluent Icons: Fluent ships
    /// with Windows 11 and MDL2 with both, and this application supports
    /// 1809.</para>
    /// </summary>
    public string Icon => ContentType switch
    {
        ContentType.Link => "\uE71B",   // Link
        ContentType.Image => "\uEB9F",  // Picture
        ContentType.File => "\uE7C3",   // Page
        _ => "\uE8C1",                  // Font / text
    };

    /// <summary>
    /// How it got here, in three words at most.
    ///
    /// <para>The distinction is worth showing: an item that went to the relay
    /// and back left the building, and one that came over the LAN did not.</para>
    /// </summary>
    public string OriginLabel => Origin switch
    {
        TransportOrigin.Lan => "over the network",
        TransportOrigin.Cloud => "through the relay",
        _ => "copied here",
    };

    /// <summary>
    /// Whether to show the padlock.
    ///
    /// <para>Only for things that travelled. Everything Hypo sends is encrypted
    /// end to end, so the glyph means "this arrived encrypted" -- and on an item
    /// copied on this machine, which never went anywhere, it would be claiming
    /// something about a journey that did not happen.</para>
    /// </summary>
    public bool Encrypted => Origin is not null;

    /// <summary>
    /// When it was copied, in the form someone reads at a glance.
    ///
    /// <para>A clock for today, a weekday for this week, a date beyond that.
    /// "14:32" answers "is this the thing I just copied?" and a full timestamp
    /// does not.</para>
    /// </summary>
    public string When => Describe(CopiedAt.ToLocalTime(), DateTimeOffset.Now);

    /// <param name="at">Already in the reader's time zone, as is <paramref name="now"/>.</param>
    internal static string Describe(DateTimeOffset at, DateTimeOffset now)
    {
        var local = at;
        var elapsed = now - local;

        if (elapsed < TimeSpan.FromMinutes(1))
        {
            return "just now";
        }

        if (local.Date == now.Date)
        {
            return local.ToString("HH:mm", CultureInfo.CurrentCulture);
        }

        return elapsed < TimeSpan.FromDays(7)
            ? local.ToString("ddd HH:mm", CultureInfo.CurrentCulture)
            : local.ToString("d MMM", CultureInfo.CurrentCulture);
    }
}

/// <summary>Which content types the list is showing.</summary>
public enum TypeFilter
{
    All,
    Text,
    Link,
    Image,
    File,
}

/// <summary>How far back the list goes.</summary>
public enum DateFilter
{
    All,
    Today,
    ThisWeek,
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

    public TypeFilter Type { get; private set; } = TypeFilter.All;

    public DateFilter Age { get; private set; } = DateFilter.All;

    /// <summary>
    /// The clock the date filter measures against. Injectable so "today" is a
    /// fact in a test rather than whenever the test happened to run.
    /// </summary>
    public Func<DateTimeOffset> Now { get; init; } = () => DateTimeOffset.Now;

    /// <summary>True when there is nothing to show. A state, not an error.</summary>
    public bool IsEmpty => Rows.Count == 0;

    /// <summary>
    /// Whether anything is narrowing the list.
    ///
    /// <para>An empty list means two different things, and the advice differs:
    /// "copy something" is wrong for a list emptied by a filter.</para>
    /// </summary>
    public bool HasNarrowedList =>
        Filter.Length > 0 || Type is not TypeFilter.All || Age is not DateFilter.All;

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

    public void SetType(TypeFilter type)
    {
        Type = type;
        Apply();
    }

    public void SetAge(DateFilter age)
    {
        Age = age;
        Apply();
    }

    /// <summary>
    /// Pins or unpins a row, and reloads so it moves.
    ///
    /// <para>A pin that did not visibly move the entry to the top would leave
    /// someone wondering whether it had worked.</para>
    /// </summary>
    public void SetPinned(HistoryRow row, bool pinned)
    {
        ArgumentNullException.ThrowIfNull(row);

        _history.SetPinned(row.Content, pinned);
        Refresh();
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
        Rows = _all.Where(row => Matches(row) && IsType(row) && IsRecentEnough(row)).ToArray();

    private bool IsType(HistoryRow row) => Type switch
    {
        TypeFilter.All => true,
        TypeFilter.Text => row.ContentType is ContentType.Text,
        TypeFilter.Link => row.ContentType is ContentType.Link,
        TypeFilter.Image => row.ContentType is ContentType.Image,
        TypeFilter.File => row.ContentType is ContentType.File,
        _ => true,
    };

    /// <summary>
    /// Whether a row survives the date filter.
    ///
    /// <para>Pinned entries always do. Someone who pinned something asked to
    /// keep it in front of them, and a filter that hid it would be overruling
    /// that.</para>
    /// </summary>
    private bool IsRecentEnough(HistoryRow row)
    {
        if (Age is DateFilter.All || row.Pinned)
        {
            return true;
        }

        var now = Now();
        var local = row.CopiedAt.ToLocalTime();

        return Age switch
        {
            // Calendar days, not the last 24 hours: "today" means today.
            DateFilter.Today => local.Date == now.Date,
            DateFilter.ThisWeek => local.Date > now.Date.AddDays(-7),
            _ => true,
        };
    }

    /// <summary>
    /// Matches the preview rather than the raw bytes.
    ///
    /// <para>Searching the content would never match an image, and would match a
    /// file only if the query happened to appear inside it. The preview is what
    /// the user is looking at, so it is what they are searching.</para>
    /// </summary>
    private bool Matches(HistoryRow row) =>
        Filter.Length == 0
        || row.Preview.Contains(Filter, StringComparison.CurrentCultureIgnoreCase)
        || row.Source.Contains(Filter, StringComparison.CurrentCultureIgnoreCase);

    private static HistoryRow ToRow(HistoryEntry entry) => new()
    {
        Content = entry.Content,
        Preview = Describe(entry.Content),
        CopiedAt = entry.CopiedAt,
        Source = entry.SourceDeviceName ?? entry.SourceDeviceId ?? "This PC",
        Origin = entry.Origin,
        Pinned = entry.Pinned,
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
