using Hypo.Core.Abstractions;
using Hypo.Core.Discovery;
using Hypo.Core.Pairing;
using Hypo.Core.Sync;

namespace Hypo.Windows.App;

/// <summary>A peer offered in the pairing list.</summary>
public sealed record PairablePeer
{
    public required DiscoveredPeer Peer { get; init; }

    public required bool AlreadyPaired { get; init; }

    public string DisplayName => Peer.DisplayName;

    public string DeviceId => Peer.DeviceId ?? Peer.InstanceName;

    /// <summary>False when this peer advertises no key and so cannot be paired with.</summary>
    public bool CanPair => !AlreadyPaired && Peer.PublicKey is not null;
}

/// <summary>
/// The pairing window's list and its one action.
///
/// <para>The interesting part is the wording of failures. `LanPairingCoordinator`
/// distinguishes a peer that never answered from one whose acknowledgement did
/// not verify, and those mean very different things: the first is usually the
/// app not being open on the phone, the second is a peer that is not who it
/// claims. Collapsing both into "pairing failed" throws that away exactly when
/// the user needs it.</para>
/// </summary>
public sealed class PairingViewModel(
    ISecretStore store,
    LanPairingCoordinator coordinator,
    string localDeviceId,
    string localDeviceName,
    SyncCoordinator? sync = null)
{
    private readonly ISecretStore _store = store ?? throw new ArgumentNullException(nameof(store));

    private readonly LanPairingCoordinator _coordinator =
        coordinator ?? throw new ArgumentNullException(nameof(coordinator));

    private readonly Dictionary<string, DiscoveredPeer> _seen = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<PairablePeer> Peers { get; private set; } = [];

    /// <summary>The last outcome, in words a person can act on.</summary>
    public string? LastMessage { get; private set; }

    /// <summary>Records a discovered peer, ignoring this device's own advertisement.</summary>
    public void Observe(DiscoveredPeer peer)
    {
        ArgumentNullException.ThrowIfNull(peer);

        if (peer.DeviceId is null
            || string.Equals(peer.DeviceId, localDeviceId, StringComparison.OrdinalIgnoreCase))
        {
            // We advertise on the network we browse, so we see ourselves.
            return;
        }

        _seen[peer.DeviceId] = peer;
        Rebuild();
    }

    public async Task<PairingResult> PairAsync(PairablePeer peer, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(peer);

        var result = await _coordinator
            .PairAsync(peer.Peer, localDeviceId, localDeviceName, ct: ct)
            .ConfigureAwait(false);

        LastMessage = Describe(result, peer.DisplayName);

        if (result.Succeeded && result.PeerDeviceId is { } paired)
        {
            // A restart to start syncing with a device you just paired would be a
            // strange thing to ask for.
            sync?.Peers.Add(paired);
        }

        Rebuild();
        return result;
    }

    public static string Describe(PairingResult result, string peerName)
    {
        ArgumentNullException.ThrowIfNull(result);

        return result.Outcome switch
        {
            PairingOutcome.Paired => $"Paired with {result.PeerDeviceName ?? peerName}.",

            PairingOutcome.PeerAdvertisesNoKey =>
                $"{peerName} is on the network but is not offering to pair. "
                + "Open Hypo on it and try again.",

            PairingOutcome.NoReply =>
                $"{peerName} accepted the connection but did not answer. "
                + "It is usually the app not being open on that device.",

            PairingOutcome.AckRejected =>
                $"{peerName} answered with a reply that did not verify. "
                + "That is not a network problem: something on this network is answering for it.",

            _ => $"Pairing with {peerName} did not complete.",
        };
    }

    private void Rebuild() =>
        Peers = _seen.Values
            .Select(peer => new PairablePeer
            {
                Peer = peer,
                AlreadyPaired = _store.Read(peer.DeviceId!) is not null,
            })
            .OrderBy(p => p.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
}
