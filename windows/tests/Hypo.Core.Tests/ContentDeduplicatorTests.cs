using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Microsoft.Extensions.Time.Testing;
using System.Text;

namespace Hypo.Core.Tests;

public class ContentDeduplicatorTests
{
    private static ClipboardContent Text(string s) =>
        new() { ContentType = ContentType.Text, Data = Encoding.UTF8.GetBytes(s) };

    private static (ContentDeduplicator Dedup, FakeTimeProvider Clock) Build(TimeSpan? window = null)
    {
        var clock = new FakeTimeProvider(DateTimeOffset.UnixEpoch);
        return (new ContentDeduplicator(clock, window ?? TimeSpan.FromSeconds(3)), clock);
    }

    [Fact]
    public void SuppressesTheSecondOfTwoIdenticalItemsInQuickSuccession()
    {
        // The measured case: the phone's two envelopes arrived within one second.
        var (dedup, clock) = Build();

        Assert.True(dedup.ShouldAccept(Text("duplicate probe")));
        clock.Advance(TimeSpan.FromMilliseconds(120));
        Assert.False(dedup.ShouldAccept(Text("duplicate probe")));
    }

    [Fact]
    public void AcceptsTheSameContentAgainAfterTheWindow()
    {
        // A person copying the same string twice is not a bug to be swallowed.
        var (dedup, clock) = Build();

        Assert.True(dedup.ShouldAccept(Text("copied twice on purpose")));
        clock.Advance(TimeSpan.FromSeconds(30));
        Assert.True(dedup.ShouldAccept(Text("copied twice on purpose")));
    }

    [Fact]
    public void DifferentContentInsideTheWindowIsNotSuppressed()
    {
        var (dedup, clock) = Build();

        Assert.True(dedup.ShouldAccept(Text("first")));
        clock.Advance(TimeSpan.FromMilliseconds(50));
        Assert.True(dedup.ShouldAccept(Text("second")));
    }

    [Fact]
    public void ARepeatingPeerDoesNotHoldTheWindowOpenForever()
    {
        // Refreshing the timestamp on a suppressed hit would let a peer
        // retrying every second keep an item suppressed indefinitely.
        var (dedup, clock) = Build(TimeSpan.FromSeconds(3));

        Assert.True(dedup.ShouldAccept(Text("retried")));
        for (var i = 0; i < 5; i++)
        {
            clock.Advance(TimeSpan.FromMilliseconds(500));
            dedup.ShouldAccept(Text("retried"));
        }

        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.True(dedup.ShouldAccept(Text("retried")));
    }

    [Fact]
    public void ARealisticBurstDoesNotEvictAnEntryTheWindowStillCovers()
    {
        var (dedup, clock) = Build();

        Assert.True(dedup.ShouldAccept(Text("the one that matters")));

        for (var i = 0; i < 200; i++)
        {
            clock.Advance(TimeSpan.FromMilliseconds(5));
            dedup.ShouldAccept(Text($"noise {i}"));
        }

        Assert.False(dedup.ShouldAccept(Text("the one that matters")));
    }

    [Fact]
    public void TheCountCapCanDiscardAStillCoveredEntry()
    {
        // Documenting the trade rather than pretending it does not exist:
        // eviction is by age, and the count cap is a backstop set far above any
        // realistic burst. When it does engage it drops the oldest, and the
        // cost is one duplicate slipping through -- which beats unbounded
        // memory in a process that runs for weeks.
        var (_, clock) = Build();
        var tiny = new ContentDeduplicator(clock, TimeSpan.FromSeconds(3)) { Capacity = 4 };

        Assert.True(tiny.ShouldAccept(Text("the one that matters")));

        for (var i = 0; i < 20; i++)
        {
            clock.Advance(TimeSpan.FromMilliseconds(10));
            tiny.ShouldAccept(Text($"noise {i}"));
        }

        Assert.True(tiny.ShouldAccept(Text("the one that matters")));
    }

    [Fact]
    public void ForgetsEntriesOnceTheyAgeOut()
    {
        var (dedup, clock) = Build(TimeSpan.FromSeconds(1));

        for (var i = 0; i < 50; i++)
        {
            dedup.ShouldAccept(Text($"item {i}"));
        }

        clock.Advance(TimeSpan.FromSeconds(5));

        Assert.True(dedup.ShouldAccept(Text("item 0")));
    }
}
