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

    /// <summary>
    /// The peer's state in words, for the list.
    ///
    /// <para>The window showed nothing but a name and an id until a screenshot
    /// made it obvious that an already-paired device looked exactly like a new
    /// one -- the distinction existed in this class and never reached the
    /// screen.</para>
    /// </summary>
    public string Status =>
        AlreadyPaired ? "Already paired"
        : Peer.PublicKey is null ? "Not offering to pair — open Hypo on it"
        : "Ready to pair";
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
    SyncCoordinator? sync = null,
    RemotePairingCoordinator? remote = null)
{
    private readonly ISecretStore _store = store ?? throw new ArgumentNullException(nameof(store));

    private readonly LanPairingCoordinator _coordinator =
        coordinator ?? throw new ArgumentNullException(nameof(coordinator));

    private readonly Dictionary<string, DiscoveredPeer> _seen = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<PairablePeer> Peers { get; private set; } = [];

    /// <summary>The last outcome, in words a person can act on.</summary>
    public string? LastMessage { get; private set; }

    /// <summary>The code this device is currently showing, if any.</summary>
    public PairingCode? ShownCode { get; private set; }

    /// <summary>Whether pairing by code is available at all.</summary>
    public bool CanPairByCode => remote is not null;

    /// <summary>
    /// Shows a code for a device that is not on this network.
    ///
    /// <para>Offered alongside the LAN list rather than instead of it: the LAN
    /// path involves no third party and nothing to carry between the devices,
    /// so it stays the front door and this is the way round when it cannot be
    /// used.</para>
    /// </summary>
    public async Task<PairingResult> ShowCodeAsync(CancellationToken ct = default)
    {
        if (remote is null)
        {
            LastMessage = "Pairing by code needs relay credentials, which this build has none of.";
            return new PairingResult(PairingOutcome.PeerAdvertisesNoKey);
        }

        try
        {
            var result = await remote.ShowCodeAsync(
                Guid.Parse(localDeviceId),
                localDeviceName,
                code =>
                {
                    ShownCode = code;
                    LastMessage = $"Enter {code.Code} on the other device.";
                    CodeShown?.Invoke(this, code);
                },
                ct).ConfigureAwait(false);

            Adopt(result, "the device that used the code");
            return result;
        }
        finally
        {
            // The code is dead either way once this returns, and leaving it on
            // screen invites someone to type an expired one.
            ShownCode = null;
        }
    }

    /// <summary>Uses a code shown on another device.</summary>
    public async Task<PairingResult> UseCodeAsync(string code, CancellationToken ct = default)
    {
        if (remote is null)
        {
            LastMessage = "Pairing by code needs relay credentials, which this build has none of.";
            return new PairingResult(PairingOutcome.PeerAdvertisesNoKey);
        }

        if (string.IsNullOrWhiteSpace(code))
        {
            LastMessage = "Type the code shown on the other device.";
            return new PairingResult(PairingOutcome.NoReply);
        }

        var result = await remote
            .UseCodeAsync(code.Trim(), localDeviceId, localDeviceName, ct)
            .ConfigureAwait(false);

        Adopt(result, "the device showing that code");
        return result;
    }

    /// <summary>Raised when a code is ready to read out.</summary>
    public event EventHandler<PairingCode>? CodeShown;

    private void Adopt(PairingResult result, string who)
    {
        LastMessage = result.Outcome switch
        {
            PairingOutcome.Paired => $"Paired with {result.PeerDeviceName ?? who}.",
            PairingOutcome.NoReply =>
                $"No answer from {who}. The code may have expired, or been typed wrong.",
            _ => "The reply did not verify. Something answered that could not have known the key.",
        };

        if (result.Succeeded && result.PeerDeviceId is { } paired)
        {
            sync?.Peers.Add(paired);
        }

        Rebuild();
    }

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
