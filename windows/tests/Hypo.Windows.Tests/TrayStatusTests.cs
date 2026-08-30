using Hypo.Core.Transport;
using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class TrayStatusTests
{
    private const TransportState Up = TransportState.Connected;
    private const TransportState Down = TransportState.Disconnected;

    [Fact]
    public void NothingReachableReadsAsOffline()
    {
        var status = TrayStatus.From(Down, Down, []);

        Assert.Equal(TrayIcon.Offline, status.Icon);
        Assert.Contains("not connected", status.Tooltip, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RelayOnlyIsDistinctFromConnected()
    {
        // A user whose relay is carrying everything should see it without opening
        // anything: it is slower and it leaves the building.
        var status = TrayStatus.From(Down, Up, []);

        Assert.Equal(TrayIcon.RelayOnly, status.Icon);
        Assert.Contains("relay", status.Tooltip, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void APeerOnTheNetworkIsConnected()
    {
        var status = TrayStatus.From(Up, Up, ["OPPO PLP110"]);

        Assert.Equal(TrayIcon.Connected, status.Icon);
        Assert.Contains("OPPO PLP110", status.Tooltip, StringComparison.Ordinal);
    }

    [Fact]
    public void AConnectedLanWithNoPeersIsNotConnected()
    {
        // The server being up means we can be reached, which says nothing about
        // whether we can reach anyone.
        var status = TrayStatus.From(Up, Up, []);

        Assert.Equal(TrayIcon.RelayOnly, status.Icon);
    }

    [Fact]
    public void SaysWhenTheRelayIsUnavailableEvenWithAPeerOnTheNetwork()
    {
        var status = TrayStatus.From(Up, Down, ["OPPO PLP110"]);

        Assert.Equal(TrayIcon.Connected, status.Icon);
        Assert.Contains("relay unavailable", status.Tooltip, StringComparison.Ordinal);
    }

    [Fact]
    public void SummarisesManyPeersRatherThanListingThemAll()
    {
        var status = TrayStatus.From(Up, Up, ["One", "Two", "Three", "Four", "Five"]);

        Assert.Contains("One, Two, Three and 2 more", status.Tooltip, StringComparison.Ordinal);
    }

    [Fact]
    public void PausedIsNotOffline()
    {
        // "I turned it off" and "it broke" must not look the same, or the user
        // retries the wrong thing.
        var status = TrayStatus.From(Down, Down, [], paused: true);

        Assert.Equal(TrayIcon.Paused, status.Icon);
        Assert.Contains("paused", status.Tooltip, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void PausedOverridesAWorkingConnection()
    {
        var status = TrayStatus.From(Up, Up, ["OPPO PLP110"], paused: true);

        Assert.Equal(TrayIcon.Paused, status.Icon);
    }
}
