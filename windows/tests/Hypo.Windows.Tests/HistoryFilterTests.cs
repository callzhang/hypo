using System.Text;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Core.Transport;
using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

/// <summary>
/// Narrowing the list, and what each row says about itself.
/// </summary>
public class HistoryFilterTests : IDisposable
{
    private static readonly DateTimeOffset Now = new(2026, 8, 31, 14, 32, 0, TimeSpan.Zero);

    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-filters").FullName;
    private readonly ClipboardHistoryStore _history;

    public HistoryFilterTests()
    {
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));

        Add(ContentType.Text, "a note to self", Now.AddMinutes(-5));
        Add(ContentType.Link, "https://example.com/thing", Now.AddHours(-3));
        Add(ContentType.Image, "not really a png", Now.AddDays(-2), TransportOrigin.Lan);
        Add(ContentType.File, "report", Now.AddDays(-20), TransportOrigin.Cloud);
    }

    public void Dispose()
    {
        _history.Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    private void Add(ContentType type, string body, DateTimeOffset at, TransportOrigin? origin = null) =>
        _history.Add(new HistoryEntry
        {
            Content = new ClipboardContent
            {
                ContentType = type,
                Data = Encoding.UTF8.GetBytes(body),
                Metadata = type is ContentType.File
                    ? new Dictionary<string, string> { ["file_name"] = body + ".pdf" }
                    : null,
            },
            CopiedAt = at,
            SourceDeviceId = origin is null ? null : "bbe296d6-0785-43d2-91b6-b135b72f4c41",
            SourceDeviceName = origin is null ? null : "OPPO PLP110",
            Origin = origin,
        });

    private sealed class NullClipboard : IClipboard
    {
        public event EventHandler<ClipboardContent>? ContentChanged;

        public Task<ClipboardContent?> GetAsync(CancellationToken ct = default)
        {
            _ = ContentChanged;
            return Task.FromResult<ClipboardContent?>(null);
        }

        public Task SetAsync(ClipboardContent content, CancellationToken ct = default) => Task.CompletedTask;
    }

    private HistoryViewModel Model()
    {
        var model = new HistoryViewModel(_history, new NullClipboard()) { Now = () => Now };
        model.Refresh();
        return model;
    }

    [Theory]
    [InlineData(TypeFilter.All, 4)]
    [InlineData(TypeFilter.Text, 1)]
    [InlineData(TypeFilter.Link, 1)]
    [InlineData(TypeFilter.Image, 1)]
    [InlineData(TypeFilter.File, 1)]
    public void TheTypeFilterKeepsOnlyThatType(TypeFilter type, int expected)
    {
        var model = Model();

        model.SetType(type);

        Assert.Equal(expected, model.Rows.Count);
    }

    [Theory]
    [InlineData(DateFilter.All, 4)]
    [InlineData(DateFilter.Today, 2)]
    [InlineData(DateFilter.ThisWeek, 3)]
    public void TheDateFilterCountsCalendarDays(DateFilter age, int expected)
    {
        // Calendar days, not the last 24 hours: something copied at 23:50
        // yesterday is not "today" at 00:10, and saying it is would be wrong in
        // the way that makes someone stop trusting the filter.
        var model = Model();

        model.SetAge(age);

        Assert.Equal(expected, model.Rows.Count);
    }

    [Fact]
    public void TheFiltersCombineWithTheSearchBox()
    {
        var model = Model();

        model.SetType(TypeFilter.Link);
        model.SetAge(DateFilter.Today);
        model.SetFilter("example");

        Assert.Single(model.Rows);

        model.SetFilter("nothing like this");
        Assert.Empty(model.Rows);
    }

    [Fact]
    public void APinnedEntrySurvivesTheDateFilter()
    {
        var model = Model();
        var oldest = model.Rows.Single(r => r.ContentType is ContentType.File);

        model.SetPinned(oldest, pinned: true);
        model.SetAge(DateFilter.Today);

        // Someone who pinned something asked to keep it in front of them. A
        // filter that hid it would be overruling that.
        Assert.Contains(model.Rows, r => r.ContentType is ContentType.File);
        Assert.True(model.Rows[0].Pinned);
    }

    [Fact]
    public void PinningMovesTheEntryToTheTop()
    {
        var model = Model();
        var oldest = model.Rows[^1];

        model.SetPinned(oldest, pinned: true);

        // A pin that did not visibly move the entry would leave someone
        // wondering whether it had worked.
        Assert.Equal(oldest.Content.Hash, model.Rows[0].Content.Hash);

        model.SetPinned(model.Rows[0], pinned: false);
        Assert.NotEqual(oldest.Content.Hash, model.Rows[0].Content.Hash);
    }

    [Fact]
    public void EachRowSaysHowItGotHere()
    {
        var model = Model();

        Assert.Equal("copied here", model.Rows.Single(r => r.ContentType is ContentType.Text).OriginLabel);
        Assert.Equal("over the network", model.Rows.Single(r => r.ContentType is ContentType.Image).OriginLabel);
        Assert.Equal("through the relay", model.Rows.Single(r => r.ContentType is ContentType.File).OriginLabel);
    }

    [Fact]
    public void ThePadlockIsOnlyOnThingsThatTravelled()
    {
        var model = Model();

        // Everything Hypo sends is encrypted end to end, so the glyph means
        // "this arrived encrypted". On something copied here, which never went
        // anywhere, it would be claiming a journey that did not happen.
        Assert.False(model.Rows.Single(r => r.ContentType is ContentType.Text).Encrypted);
        Assert.True(model.Rows.Single(r => r.ContentType is ContentType.Image).Encrypted);
        Assert.True(model.Rows.Single(r => r.ContentType is ContentType.File).Encrypted);
    }

    [Fact]
    public void EveryContentTypeHasItsOwnGlyph()
    {
        var glyphs = Model().Rows.Select(r => r.Icon).ToArray();

        Assert.Equal(4, glyphs.Distinct().Count());
        Assert.All(glyphs, glyph => Assert.Single(glyph));
    }

    [Theory]
    [InlineData(0, "just now")]
    [InlineData(-90, "13:02")]
    [InlineData(-60 * 26, "Sun 12:32")]
    [InlineData(-60 * 24 * 20, "11 Aug")]
    public void TheTimeIsWrittenAtTheGrainSomeoneReads(int minutesAgo, string expected)
    {
        // "14:32" answers "is this the thing I just copied?" and a full
        // timestamp does not.
        var at = Now.AddMinutes(minutesAgo);

        Assert.Equal(expected, HistoryRow.Describe(at, Now));
    }
}
