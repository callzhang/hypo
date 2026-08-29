using Hypo.Core.Crypto;
using Hypo.Core.Pairing;

namespace Hypo.Core.Tests;

public class PairingSessionTests
{
    private const string InitiatorId = "550e8400-e29b-41d4-a716-446655440000";
    private static readonly Guid ResponderId = Guid.Parse("bbe296d6-0785-43d2-91b6-b135b72f4c41");

    private static (PairingSession Responder, byte[] ResponderPublicKey) StartResponder()
    {
        var session = PairingSession.StartResponder(ResponderId, "Peer");
        return (session, session.AgreementPublicKey);
    }

    [Fact]
    public void TheResponderPublishesAnAgreementKeyBeforeAnyChallenge()
    {
        var (_, publicKey) = StartResponder();

        Assert.Equal(CryptoService.X25519KeySizeBytes, publicKey.Length);
    }

    [Fact]
    public void EveryAttemptGeneratesAFreshKey()
    {
        // Protocol section 9.2's rotation claim is the one part of it that holds.
        Assert.NotEqual(StartResponder().ResponderPublicKey, StartResponder().ResponderPublicKey);
    }

    [Fact]
    public void BothSidesDeriveTheSameKey()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");

        var challenge = initiator.CreateChallenge(responderPublicKey);
        var result = responder.AcceptChallenge(challenge);

        Assert.NotNull(result);
        Assert.Equal(CryptoService.KeySizeBytes, result.SharedKey.Length);

        var completed = initiator.CompleteWithAck(result.Ack, responderPublicKey);
        Assert.NotNull(completed);
        Assert.Equal(result.SharedKey, completed.SharedKey);
    }

    [Fact]
    public void TheCompletedPairingNamesThePeer()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");

        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderPublicKey))!;
        var completed = initiator.CompleteWithAck(result.Ack, responderPublicKey)!;

        Assert.Equal(ResponderId.ToString("D"), completed.PeerDeviceId);
        Assert.Equal("Peer", completed.PeerDeviceName);
        Assert.Equal(InitiatorId, result.PeerDeviceId);
        Assert.Equal("Test PC", result.PeerDeviceName);
    }

    [Fact]
    public void AChallengeFromTheWrongKeyIsRejected()
    {
        var (responder, _) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var (_, strangerKey) = StartResponder();

        // Encrypted against a key the responder does not hold.
        Assert.Null(responder.AcceptChallenge(initiator.CreateChallenge(strangerKey)));
    }

    [Fact]
    public void ATamperedAckIsRejected()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderPublicKey))!;

        var tampered = result.Ack with { Tag = result.Ack.Tag.Select(b => (byte)(b ^ 0xFF)).ToArray() };

        Assert.Null(initiator.CompleteWithAck(tampered, responderPublicKey));
    }

    [Fact]
    public void AnAckForAnotherChallengeIsRejected()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderPublicKey))!;

        var wrongId = result.Ack with { ChallengeId = Guid.NewGuid() };

        Assert.Null(initiator.CompleteWithAck(wrongId, responderPublicKey));
    }

    [Fact]
    public void AnAckWhoseResponseHashDoesNotMatchIsRejected()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderPublicKey))!;

        // A second challenge from the SAME session. The shared key is unchanged,
        // so the first ack still decrypts cleanly and the hash comparison is
        // actually reached — but the pending challenge has moved on, so the hash
        // no longer matches. Borrowing an ack from a *different* session would
        // make this vacuous: it would fail to decrypt and the comparison would
        // never run.
        var second = initiator.CreateChallenge(responderPublicKey);

        Assert.Null(initiator.CompleteWithAck(
            result.Ack with { ChallengeId = second.ChallengeId }, responderPublicKey));
    }

    [Fact]
    public void ReplayingAChallengeIdIsRejected()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var challenge = initiator.CreateChallenge(responderPublicKey);

        Assert.NotNull(responder.AcceptChallenge(challenge));
        Assert.Null(responder.AcceptChallenge(challenge));
    }

    [Fact]
    public void AStaleChallengeIsRejected()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(
            InitiatorId, "Test PC", clock: () => DateTimeOffset.UtcNow.AddMinutes(-10));

        Assert.Null(responder.AcceptChallenge(initiator.CreateChallenge(responderPublicKey)));
    }
}
