using Hypo.Core.Transport;

namespace Hypo.Windows.App;

/// <summary>
/// The two things the tray icon needs to know.
///
/// <para>Narrower than <c>HypoClient</c> on purpose. The tray took the whole
/// client, which meant testing the menu required a relay connection, a key
/// store and a live network -- so the class with the most wiring in the
/// application had no tests at all.</para>
/// </summary>
public interface ISyncStatusSource
{
    /// <summary>Device ids reachable on the local network right now.</summary>
    IReadOnlyCollection<string> LanPeers { get; }

    /// <summary>Whether either transport can carry a message.</summary>
    TransportState State { get; }
}

/// <summary>Presents a <see cref="Hypo.Core.Client.HypoClient"/> as a status source.</summary>
public sealed class ClientStatusSource(Hypo.Core.Client.HypoClient client) : ISyncStatusSource
{
    public IReadOnlyCollection<string> LanPeers => client.LanPeers;

    public TransportState State => client.State;
}
