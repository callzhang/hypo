using System.Text.Json;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class PairingOverLanTests
{
    private const string InitiatorId = "550e8400-e29b-41d4-a716-446655440000";
    private static readonly Guid ResponderId = Guid.Parse("bbe296d6-0785-43d2-91b6-b135b72f4c41");

    [Fact]
    public void TheChallengeSurvivesAJsonRoundTrip()
    {
        var responder = PairingSession.StartResponder(ResponderId, "Peer");
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");

        var challenge = initiator.CreateChallenge(responder.AgreementPublicKey);
        var wire = JsonSerializer.Serialize(challenge, ProtocolJson.Options);
        var back = JsonSerializer.Deserialize<PairingChallengeMessage>(wire, ProtocolJson.Options)!;

        var result = responder.AcceptChallenge(back);

        Assert.NotNull(result);
    }

    [Fact]
    public void TheAckSurvivesAJsonRoundTrip()
    {
        var responder = PairingSession.StartResponder(ResponderId, "Peer");
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var responderKey = responder.AgreementPublicKey;

        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderKey))!;
        var wire = JsonSerializer.Serialize(result.Ack, ProtocolJson.Options);
        var back = JsonSerializer.Deserialize<PairingAckMessage>(wire, ProtocolJson.Options)!;

        var completed = initiator.CompleteWithAck(back, responderKey);

        Assert.NotNull(completed);
        Assert.Equal(result.SharedKey, completed.SharedKey);
    }

    [Fact]
    public void TheDerivedKeyEncryptsAClipboardPayloadBothWays()
    {
        // The point of pairing: the key it produces has to work for the traffic
        // that follows, with the associated data the sync path actually uses.
        var responder = PairingSession.StartResponder(ResponderId, "Peer");
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var responderKey = responder.AgreementPublicKey;

        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderKey))!;
        var completed = initiator.CompleteWithAck(result.Ack, responderKey)!;

        var plaintext = "clipboard contents"u8.ToArray();
        var nonce = new byte[Hypo.Core.Crypto.CryptoService.NonceSizeBytes];
        System.Security.Cryptography.RandomNumberGenerator.Fill(nonce);
        var aad = Hypo.Core.Crypto.CryptoService.BuildAssociatedData(InitiatorId);

        var (ciphertext, tag) = Hypo.Core.Crypto.CryptoService.Encrypt(
            plaintext, completed.SharedKey, nonce, aad);

        var decrypted = Hypo.Core.Crypto.CryptoService.Decrypt(
            ciphertext, result.SharedKey, nonce, tag, aad);

        Assert.Equal(plaintext, decrypted);
    }
}
