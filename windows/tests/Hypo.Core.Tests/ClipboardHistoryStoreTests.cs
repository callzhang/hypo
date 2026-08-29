using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using System.Text;

namespace Hypo.Core.Tests;

public class ClipboardHistoryStoreTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-history").FullName;

    private string Path(string name = "history.db") => System.IO.Path.Combine(_dir, name);

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private static HistoryEntry Entry(string text, DateTimeOffset at, string? from = null) => new()
    {
        Content = new ClipboardContent { ContentType = ContentType.Text, Data = Encoding.UTF8.GetBytes(text) },
        CopiedAt = at,
        SourceDeviceId = from,
    };

    [Fact]
    public void SurvivesReopening()
    {
        var path = Path();
        using (var store = new ClipboardHistoryStore(path))
        {
            store.Add(Entry("persisted", DateTimeOffset.UnixEpoch));
        }

        using var reopened = new ClipboardHistoryStore(path);

        Assert.Equal("persisted", Encoding.UTF8.GetString(reopened.Recent()[0].Content.Data));
    }

    [Fact]
    public void ReturnsNewestFirst()
    {
        using var store = new ClipboardHistoryStore(Path());
        store.Add(Entry("older", DateTimeOffset.UnixEpoch));
        store.Add(Entry("newer", DateTimeOffset.UnixEpoch.AddMinutes(1)));

        var recent = store.Recent();

        Assert.Equal("newer", Encoding.UTF8.GetString(recent[0].Content.Data));
        Assert.Equal("older", Encoding.UTF8.GetString(recent[1].Content.Data));
    }

    [Fact]
    public void ReAddingExistingContentMovesItRatherThanDuplicating()
    {
        // What the phone does. Matching it keeps the two histories legible side
        // by side, which matters when diagnosing sync.
        using var store = new ClipboardHistoryStore(Path());
        store.Add(Entry("repeated", DateTimeOffset.UnixEpoch));
        store.Add(Entry("other", DateTimeOffset.UnixEpoch.AddMinutes(1)));
        store.Add(Entry("repeated", DateTimeOffset.UnixEpoch.AddMinutes(2)));

        var recent = store.Recent();

        Assert.Equal(2, recent.Count);
        Assert.Equal("repeated", Encoding.UTF8.GetString(recent[0].Content.Data));
    }

    [Fact]
    public void DropsTheOldestBeyondCapacity()
    {
        using var store = new ClipboardHistoryStore(Path(), capacity: 3);
        for (var i = 0; i < 6; i++)
        {
            store.Add(Entry($"item {i}", DateTimeOffset.UnixEpoch.AddMinutes(i)));
        }

        var recent = store.Recent();

        Assert.Equal(3, recent.Count);
        Assert.Equal("item 5", Encoding.UTF8.GetString(recent[0].Content.Data));
        Assert.DoesNotContain(recent, e => Encoding.UTF8.GetString(e.Content.Data) == "item 0");
    }

    [Fact]
    public void KeepsTheSourceDevice()
    {
        using var store = new ClipboardHistoryStore(Path());
        store.Add(Entry("from the phone", DateTimeOffset.UnixEpoch, from: "bbe296d6-0785-43d2-91b6-b135b72f4c41"));

        Assert.Equal("bbe296d6-0785-43d2-91b6-b135b72f4c41", store.Recent()[0].SourceDeviceId);
    }

    [Fact]
    public void PreservesBytesExactly()
    {
        // Blob round-tripping is where an encoding assumption would hide: an
        // image is not text, and text is not always valid UTF-8.
        var bytes = new byte[] { 0x00, 0xFF, 0xFE, 0x80, 0x7F, 0x00 };
        using var store = new ClipboardHistoryStore(Path());
        store.Add(new HistoryEntry
        {
            Content = new ClipboardContent { ContentType = ContentType.Image, Data = bytes },
            CopiedAt = DateTimeOffset.UnixEpoch,
        });

        Assert.Equal(bytes, store.Recent()[0].Content.Data);
        Assert.Equal(ContentType.Image, store.Recent()[0].Content.ContentType);
    }

    [Fact]
    public void RebuildsRatherThanRefusingToStartOnACorruptFile()
    {
        // A clipboard tool that will not launch because its history is damaged
        // has turned a cosmetic problem into a fatal one. The history is a
        // convenience; syncing is the product.
        var path = Path("corrupt.db");
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes("this is emphatically not a SQLite database"));

        using var store = new ClipboardHistoryStore(path);
        store.Add(Entry("after the rebuild", DateTimeOffset.UnixEpoch));

        Assert.Equal("after the rebuild", Encoding.UTF8.GetString(store.Recent()[0].Content.Data));
    }

    [Fact]
    public void RoundTripsTimestampsWithoutLosingTheOffset()
    {
        var at = new DateTimeOffset(2026, 8, 29, 14, 30, 15, TimeSpan.FromHours(8));
        using var store = new ClipboardHistoryStore(Path());
        store.Add(Entry("timestamped", at));

        Assert.Equal(at.ToUniversalTime(), store.Recent()[0].CopiedAt.ToUniversalTime());
    }
}
