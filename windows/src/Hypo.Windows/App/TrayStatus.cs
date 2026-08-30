using Hypo.Core.Transport;

namespace Hypo.Windows.App;

/// <summary>Which icon the tray should show. Ordered from worst to best.</summary>
public enum TrayIcon
{
    /// <summary>Nothing is reachable.</summary>
    Offline,

    /// <summary>The user turned syncing off. Deliberately not <see cref="Offline"/>.</summary>
    Paused,

    /// <summary>Reachable, but only through the relay.</summary>
    RelayOnly,

    /// <summary>At least one peer is on the local network.</summary>
    Connected,
}

/// <summary>
/// What the tray icon shows, derived from the transports.
///
/// <para>A pure function of state, so the one part of the tray that carries
/// meaning can be tested without a tray. The alternative -- deciding this inside
/// an icon-updating handler -- would make it the least verified code in the
/// application and the most looked at.</para>
/// </summary>
public sealed record TrayStatus
{
    /// <summary>Names beyond this are summarised; a tooltip is not a list.</summary>
    private const int MaxNamedPeers = 3;

    public required TrayIcon Icon { get; init; }

    public required string Tooltip { get; init; }

    public static TrayStatus From(
        TransportState lan,
        TransportState relay,
        IReadOnlyCollection<string> lanPeerNames,
        bool paused = false)
    {
        ArgumentNullException.ThrowIfNull(lanPeerNames);

        if (paused)
        {
            // Distinct from offline on purpose: "I turned it off" and "it broke"
            // must not look the same, or the user retries the wrong thing.
            return new TrayStatus { Icon = TrayIcon.Paused, Tooltip = "Hypo — paused" };
        }

        var lanUp = lan == TransportState.Connected && lanPeerNames.Count > 0;
        var relayUp = relay == TransportState.Connected;

        if (lanUp)
        {
            return new TrayStatus
            {
                Icon = TrayIcon.Connected,
                Tooltip = $"Hypo — {Describe(lanPeerNames)} on this network"
                          + (relayUp ? ", relay available" : ", relay unavailable"),
            };
        }

        if (relayUp)
        {
            // Worth distinguishing rather than calling it connected: a user whose
            // relay is carrying everything should be able to see that without
            // opening anything, because it is slower and leaves the building.
            return new TrayStatus
            {
                Icon = TrayIcon.RelayOnly,
                Tooltip = "Hypo — syncing through the relay; no devices on this network",
            };
        }

        return new TrayStatus { Icon = TrayIcon.Offline, Tooltip = "Hypo — not connected" };
    }

    private static string Describe(IReadOnlyCollection<string> names)
    {
        var listed = names.Take(MaxNamedPeers).ToArray();
        var remainder = names.Count - listed.Length;

        return remainder > 0
            ? $"{string.Join(", ", listed)} and {remainder} more"
            : string.Join(", ", listed);
    }
}
