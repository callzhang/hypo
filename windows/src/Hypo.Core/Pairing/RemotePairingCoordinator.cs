using System.Text.Json;
using Hypo.Core.Abstractions;
using Hypo.Core.Protocol;

namespace Hypo.Core.Pairing;

/// <summary>
/// Pairing two devices that are not on the same network, through a six-digit
/// code the user carries between them.
///
/// <para>Without this, pairing needs both devices on one LAN -- so a phone on
/// cellular, or a laptop on a different network, cannot be paired with at all.
/// The LAN path stays the better one when it is available: it involves no third
/// party and no code to read out.</para>
///
/// <para><b>The relay's role names are the reverse of this codebase's.</b> The
/// side that <em>shows</em> the code answers the challenge, which is a
/// <see cref="PairingSession.StartResponder"/>; the side that <em>types</em> it
/// sends one, which is <see cref="PairingSession.StartInitiator"/>. The relay
/// calls the first "initiator" because it initiated the code.</para>
/// </summary>
public sealed class RemotePairingCoordinator(RelayPairingClient relay, ISecretStore store)
{
    private readonly RelayPairingClient _relay = relay ?? throw new ArgumentNullException(nameof(relay));
    private readonly ISecretStore _store = store ?? throw new ArgumentNullException(nameof(store));

    /// <summary>How often to ask the relay whether the other side has answered.</summary>
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>
    /// Shows a code and waits for someone to use it.
    ///
    /// <para>This side ends up as the pairing responder: it receives a challenge
    /// and answers it.</para>
    /// </summary>
    public async Task<PairingResult> ShowCodeAsync(
        Guid localDeviceId,
        string localDeviceName,
        Action<PairingCode> onCode,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(onCode);

        var session = PairingSession.StartResponder(localDeviceId, localDeviceName);

        var code = await _relay
            .CreateCodeAsync(localDeviceId.ToString(), localDeviceName, session.AgreementPublicKey, ct)
            .ConfigureAwait(false);

        onCode(code);

        var challengeJson = await PollAsync(
            () => _relay.PollChallengeAsync(code.Code, localDeviceId.ToString(), ct), code.ExpiresAt, ct).ConfigureAwait(false);

        if (challengeJson is null)
        {
            return new PairingResult(PairingOutcome.NoReply);
        }

        PairingChallengeMessage? challenge;
        try
        {
            challenge = JsonSerializer.Deserialize<PairingChallengeMessage>(challengeJson, ProtocolJson.Options);
        }
        catch (JsonException)
        {
            return new PairingResult(PairingOutcome.AckRejected);
        }

        var accepted = challenge is null ? null : session.AcceptChallenge(challenge);
        if (accepted is null)
        {
            // The challenge did not verify. Not a network problem: someone
            // answered the code who could not have known the key.
            return new PairingResult(PairingOutcome.AckRejected);
        }

        await _relay.SubmitAckAsync(
            code.Code,
            localDeviceId.ToString(),
            JsonSerializer.Serialize(accepted.Ack, ProtocolJson.Options),
            ct).ConfigureAwait(false);

        _store.Write(accepted.PeerDeviceId, accepted.SharedKey);

        // Beside the key, so anything showing a list of paired devices has
        // something to show. Without it the only handle on a peer is its GUID.
        PairedDevices.Remember(_store, accepted.PeerDeviceId, accepted.PeerDeviceName);

        return new PairingResult(PairingOutcome.Paired, accepted.PeerDeviceId, accepted.PeerDeviceName);
    }

    /// <summary>
    /// Uses a code someone read out.
    ///
    /// <para>This side is the pairing initiator: it sends the challenge and
    /// waits for the acknowledgement.</para>
    /// </summary>
    public async Task<PairingResult> UseCodeAsync(
        string code,
        string localDeviceId,
        string localDeviceName,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(code);

        var session = PairingSession.StartInitiator(localDeviceId, localDeviceName);

        ClaimedCode claimed;
        try
        {
            claimed = await _relay
                .ClaimCodeAsync(code, localDeviceId, localDeviceName, session.AgreementPublicKey, ct)
                .ConfigureAwait(false);
        }
        catch (PairingRelayException)
        {
            // A wrong or expired code is the ordinary failure here, and the one
            // a user is most likely to cause.
            return new PairingResult(PairingOutcome.NoReply);
        }

        var challenge = session.CreateChallenge(claimed.PeerPublicKey);

        await _relay.SubmitChallengeAsync(
            code,
            localDeviceId,
            JsonSerializer.Serialize(challenge, ProtocolJson.Options),
            ct).ConfigureAwait(false);

        var ackJson = await PollAsync(
            () => _relay.PollAckAsync(code, localDeviceId, ct), claimed.ExpiresAt, ct).ConfigureAwait(false);

        if (ackJson is null)
        {
            return new PairingResult(PairingOutcome.NoReply);
        }

        PairingAckMessage? ack;
        try
        {
            ack = JsonSerializer.Deserialize<PairingAckMessage>(ackJson, ProtocolJson.Options);
        }
        catch (JsonException)
        {
            return new PairingResult(PairingOutcome.AckRejected);
        }

        var completed = ack is null ? null : session.CompleteWithAck(ack, claimed.PeerPublicKey);
        if (completed is null)
        {
            return new PairingResult(PairingOutcome.AckRejected);
        }

        _store.Write(completed.PeerDeviceId, completed.SharedKey);

        PairedDevices.Remember(_store, completed.PeerDeviceId, completed.PeerDeviceName);

        return new PairingResult(PairingOutcome.Paired, completed.PeerDeviceId, completed.PeerDeviceName);
    }

    /// <summary>
    /// Asks until there is an answer or the code expires.
    ///
    /// <para>Bounded by the code's own expiry rather than a timeout of our
    /// choosing: once it has expired nothing can arrive, and polling past that
    /// only delays telling the user.</para>
    /// </summary>
    private async Task<string?> PollAsync(
        Func<Task<string?>> poll, DateTimeOffset expiresAt, CancellationToken ct)
    {
        while (DateTimeOffset.UtcNow < expiresAt)
        {
            if (await poll().ConfigureAwait(false) is { } answer)
            {
                return answer;
            }

            await Task.Delay(PollInterval, ct).ConfigureAwait(false);
        }

        return null;
    }
}
