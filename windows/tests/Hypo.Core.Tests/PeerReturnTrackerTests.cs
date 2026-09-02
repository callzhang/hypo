using Hypo.Core.Presence;

namespace Hypo.Core.Tests;

/// <summary>
/// When a peer coming back is worth interrupting someone for.
/// </summary>
public class PeerReturnTrackerTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-presence").FullName;
    private readonly DateTimeOffset _start = new(2026, 9, 2, 9, 0, 0, TimeSpan.Zero);
    private static readonly string[] Peers = ["aaaa1111"];

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public void AnnouncesAPeerBackAfterMoreThanADay()
    {
        var tracker = new PeerReturnTracker(_dir);
        tracker.Observe([], Peers, _start);

        var returned = tracker.Observe(Peers, Peers, _start + PeerReturnTracker.Threshold + TimeSpan.FromMinutes(1));

        Assert.Equal(["aaaa1111"], returned);
    }

    [Fact]
    public void SaysNothingForAPeerThatJustFlickered()
    {
        var tracker = new PeerReturnTracker(_dir);
        tracker.Observe([], Peers, _start);

        // A screen going to sleep and waking up again.
        var returned = tracker.Observe(Peers, Peers, _start + TimeSpan.FromMinutes(2));

        Assert.Empty(returned);
    }

    [Fact]
    public void SaysNothingAboutAPeerItNeverSawGoOffline()
    {
        var tracker = new PeerReturnTracker(_dir);

        // First run: everything is simply present.
        Assert.Empty(tracker.Observe(Peers, Peers, _start));
    }

    [Fact]
    public void RepeatedPollsWhileOfflineDoNotResetTheClock()
    {
        var tracker = new PeerReturnTracker(_dir);
        tracker.Observe([], Peers, _start);

        // The poller runs every ten minutes; each one must not push the deadline out.
        for (var minutes = 10; minutes < 24 * 60; minutes += 10)
        {
            tracker.Observe([], Peers, _start + TimeSpan.FromMinutes(minutes));
        }

        var returned = tracker.Observe(Peers, Peers, _start + TimeSpan.FromHours(25));

        Assert.Equal(["aaaa1111"], returned);
    }

    /// <summary>The interesting case spans a restart, so the record has to outlive it.</summary>
    [Fact]
    public void RemembersAnAbsenceAcrossARestart()
    {
        new PeerReturnTracker(_dir).Observe([], Peers, _start);

        var afterRestart = new PeerReturnTracker(_dir);
        var returned = afterRestart.Observe(Peers, Peers, _start + TimeSpan.FromHours(30));

        Assert.Equal(["aaaa1111"], returned);
    }

    [Fact]
    public void AnnouncesEachReturnOnlyOnce()
    {
        var tracker = new PeerReturnTracker(_dir);
        tracker.Observe([], Peers, _start);
        var later = _start + TimeSpan.FromHours(25);

        Assert.Single(tracker.Observe(Peers, Peers, later));
        Assert.Empty(tracker.Observe(Peers, Peers, later + TimeSpan.FromMinutes(10)));
    }

    [Fact]
    public void MatchesPeersRegardlessOfCasing()
    {
        var tracker = new PeerReturnTracker(_dir);
        tracker.Observe([], ["AAAA1111"], _start);

        var returned = tracker.Observe(["aaaa1111"], ["AAAA1111"], _start + TimeSpan.FromHours(25));

        Assert.Equal(["aaaa1111"], returned);
    }
}
