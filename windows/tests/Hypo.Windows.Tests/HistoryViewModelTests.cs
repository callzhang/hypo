using System.Text;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class HistoryViewModelTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-history-vm").FullName;
    private readonly ClipboardHistoryStore _history;
    private readonly RecordingClipboard _clipboard = new();

    public HistoryViewModelTests() =>
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));

    public void Dispose()
    {
        _history.Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    /// <summary>
    /// Records writes and, like the real one, never republishes them as changes.
    /// A fake that echoed would let the history window resend every entry the
    /// user merely looked at.
    /// </summary>
    private sealed class RecordingClipboard : IClipboard
    {
        public event EventHandler<ClipboardContent>? ContentChanged;

        public List<ClipboardContent> Writes { get; } = [];

        public int Changes { get; private set; }

        public RecordingClipboard() => ContentChanged += (_, _) => Changes++;

        public Task<ClipboardContent?> GetAsync(CancellationToken ct = default) =>
            Task.FromResult<ClipboardContent?>(Writes.LastOrDefault());

        public Task SetAsync(ClipboardContent content, CancellationToken ct = default)
        {
            Writes.Add(content);
            return Task.CompletedTask;
        }
    }

    private void Add(string text, DateTimeOffset at, string? from = null) => _history.Add(new HistoryEntry
    {
        Content = new ClipboardContent { ContentType = ContentType.Text, Data = Encoding.UTF8.GetBytes(text) },
        CopiedAt = at,
        SourceDeviceName = from,
        SourceDeviceId = from is null ? null : "peer-id",
    });

    private HistoryViewModel Build()
    {
        var model = new HistoryViewModel(_history, _clipboard);
        model.Refresh();
        return model;
    }

    [Fact]
    public void ShowsNewestFirst()
    {
        Add("older", DateTimeOffset.UnixEpoch);
        Add("newer", DateTimeOffset.UnixEpoch.AddMinutes(1));

        var model = Build();

        Assert.Equal("newer", model.Rows[0].Preview);
        Assert.Equal("older", model.Rows[1].Preview);
    }

    [Fact]
    public void AnEmptyHistoryIsAStateNotAnError()
    {
        var model = Build();

        Assert.True(model.IsEmpty);
        Assert.Empty(model.Rows);
    }

    [Fact]
    public void CollapsesMultiLineContentIntoOneRow()
    {
        // A pasted stack trace is one row like anything else.
        Add("first line\r\n\tsecond line\nthird", DateTimeOffset.UnixEpoch);

        Assert.Equal("first line second line third", Build().Rows[0].Preview);
    }

    [Fact]
    public void DescribesBlankContentRatherThanShowingNothing()
    {
        Add("   \n  ", DateTimeOffset.UnixEpoch);

        Assert.Equal("(blank)", Build().Rows[0].Preview);
    }

    [Fact]
    public void NamesAFileAndSizesAnImage()
    {
        _history.Add(new HistoryEntry
        {
            Content = new ClipboardContent
            {
                ContentType = ContentType.File,
                Data = [1, 2, 3],
                Metadata = new Dictionary<string, string> { ["file_name"] = "report.pdf" },
            },
            CopiedAt = DateTimeOffset.UnixEpoch.AddMinutes(1),
        });
        _history.Add(new HistoryEntry
        {
            Content = new ClipboardContent { ContentType = ContentType.Image, Data = new byte[2048] },
            CopiedAt = DateTimeOffset.UnixEpoch,
        });

        var model = Build();

        Assert.Equal("report.pdf", model.Rows[0].Preview);
        Assert.StartsWith("Image, 2", model.Rows[1].Preview, StringComparison.Ordinal);
    }

    [Fact]
    public void FiltersCaseInsensitively()
    {
        Add("Hello Clipboard", DateTimeOffset.UnixEpoch.AddMinutes(1));
        Add("something else", DateTimeOffset.UnixEpoch);

        var model = Build();
        model.SetFilter("HELLO");

        Assert.Equal("Hello Clipboard", Assert.Single(model.Rows).Preview);
    }

    [Fact]
    public void FiltersMatchAFileByName()
    {
        // Searching raw bytes would never match an image, and would match a file
        // only if the query happened to appear inside it.
        _history.Add(new HistoryEntry
        {
            Content = new ClipboardContent
            {
                ContentType = ContentType.File,
                Data = [0xFF, 0xFE],
                Metadata = new Dictionary<string, string> { ["file_name"] = "quarterly-report.pdf" },
            },
            CopiedAt = DateTimeOffset.UnixEpoch,
        });

        var model = Build();
        model.SetFilter("quarterly");

        Assert.Single(model.Rows);
    }

    [Fact]
    public void FiltersMatchTheSourceDevice()
    {
        Add("from the phone", DateTimeOffset.UnixEpoch.AddMinutes(1), from: "OPPO PLP110");
        Add("from here", DateTimeOffset.UnixEpoch);

        var model = Build();
        model.SetFilter("OPPO");

        Assert.Equal("from the phone", Assert.Single(model.Rows).Preview);
    }

    [Fact]
    public void ClearingTheFilterRestoresEverything()
    {
        Add("one", DateTimeOffset.UnixEpoch.AddMinutes(1));
        Add("two", DateTimeOffset.UnixEpoch);

        var model = Build();
        model.SetFilter("one");
        model.SetFilter("");

        Assert.Equal(2, model.Rows.Count);
    }

    [Fact]
    public async Task UsingAnEntryPutsItBackWithoutLookingLikeANewCopy()
    {
        // Without this, browsing history would resend every entry the user
        // merely glanced at to all of their devices.
        Add("an old entry", DateTimeOffset.UnixEpoch);

        var model = Build();
        await model.UseAsync(model.Rows[0]);

        Assert.Equal("an old entry", Encoding.UTF8.GetString(Assert.Single(_clipboard.Writes).Data));
        Assert.Equal(0, _clipboard.Changes);
    }

    [Fact]
    public void RefreshShowsSomethingThatArrivedSince()
    {
        var model = Build();
        Assert.True(model.IsEmpty);

        Add("arrived later", DateTimeOffset.UnixEpoch);
        model.Refresh();

        Assert.Equal("arrived later", Assert.Single(model.Rows).Preview);
    }

    [Fact]
    public void RefreshKeepsTheFilterApplied()
    {
        Add("keep me", DateTimeOffset.UnixEpoch.AddMinutes(1));
        Add("drop me", DateTimeOffset.UnixEpoch);

        var model = Build();
        model.SetFilter("keep");
        model.Refresh();

        Assert.Single(model.Rows);
    }

    [Fact]
    public void ShowsWhereAnEntryCameFrom()
    {
        Add("from the phone", DateTimeOffset.UnixEpoch.AddMinutes(1), from: "OPPO PLP110");
        Add("copied here", DateTimeOffset.UnixEpoch);

        var model = Build();

        Assert.Equal("OPPO PLP110", model.Rows[0].Source);
        Assert.Equal("This PC", model.Rows[1].Source);
    }
}
