using System.Text.Json;
using Hypo.Core.Abstractions;
using Hypo.Core.Discovery;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;

namespace Hypo.Core.Pairing;

/// <summary>Why a pairing attempt ended the way it did.</summary>
public enum PairingOutcome
{
    Paired,

    /// <summary>The peer advertises no agreement key, so there is nothing to pair against.</summary>
    PeerAdvertisesNoKey,

    /// <summary>Connected, and no parseable acknowledgement arrived in time.</summary>
    NoReply,

    /// <summary>An acknowledgement arrived and its signature did not verify.</summary>
    AckRejected,
}

public sealed record PairingResult(
    PairingOutcome Outcome,
    string? PeerDeviceId = null,
    string? PeerDeviceName = null)
{
    public bool Succeeded => Outcome == PairingOutcome.Paired;
}

/// <summary>
/// Runs the initiator half of LAN pairing and stores the resulting key.
///
/// <para>Extracted from the harness so the shipping client does not carry a
/// second copy. Two implementations of a handshake drift, and the one that
/// drifts is the one without the tests.</para>
///
/// <para>The exchange itself is deliberately not framed: a challenge and its
/// acknowledgement travel as bare JSON, because both shipping peers detect a
/// challenge by looking for <c>initiator_device_id</c> in the body, and
/// length-prefixing would bury that inside base64. See the design spec §3.2.1.</para>
/// </summary>
public sealed class LanPairingCoordinator(ISecretStore store)
{
    private readonly ISecretStore _store = store ?? throw new ArgumentNullException(nameof(store));

    public async Task<PairingResult> PairAsync(
        DiscoveredPeer peer,
        string localDeviceId,
        string localDeviceName,
        TimeSpan? timeout = null,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(peer);
        ArgumentException.ThrowIfNullOrWhiteSpace(localDeviceId);

        if (peer.PublicKey is null)
        {
            return new PairingResult(PairingOutcome.PeerAdvertisesNoKey);
        }

        var session = PairingSession.StartInitiator(localDeviceId, localDeviceName);
        var challenge = session.CreateChallenge(peer.PublicKey);

        await using var client = new LanWebSocketClient(peer, localDeviceId);
        var ackReceived = new TaskCompletionSource<PairingAckMessage>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        client.PairingMessageReceived += (_, e) =>
        {
            try
            {
                var ack = JsonSerializer.Deserialize<PairingAckMessage>(e.Json, ProtocolJson.Options);
                if (ack is not null)
                {
                    ackReceived.TrySetResult(ack);
                }
            }
            catch (JsonException)
            {
                // A message we cannot parse is not the one we are waiting for.
                // Keep waiting rather than failing the pairing on it.
            }
        };

        await client.ConnectAsync(ct).ConfigureAwait(false);
        await client.SendPairingAsync(challenge, ct).ConfigureAwait(false);

        PairingAckMessage ack;
        try
        {
            ack = await ackReceived.Task
                .WaitAsync(timeout ?? TimeSpan.FromSeconds(30), ct)
                .ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // Worth stating precisely, because the two cases look identical from
            // here: either the peer never answered, or it answered in a shape we
            // dropped. Distinguishing them needs a probe that logs raw frames.
            return new PairingResult(PairingOutcome.NoReply);
        }

        var completed = session.CompleteWithAck(ack, peer.PublicKey);
        if (completed is null)
        {
            return new PairingResult(PairingOutcome.AckRejected);
        }

        _store.Write(completed.PeerDeviceId, completed.SharedKey);

        return new PairingResult(
            PairingOutcome.Paired, completed.PeerDeviceId, completed.PeerDeviceName);
    }
}
