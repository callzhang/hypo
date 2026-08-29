using System.Text.Json;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class PairingMessagesTests
{
    private const string ChallengeJson = """
    {
      "challenge_id": "11111111-1111-1111-1111-111111111111",
      "initiator_device_id": "550e8400-e29b-41d4-a716-446655440000",
      "initiator_device_name": "Test PC",
      "initiator_pub_key": "0KWinOak3zMKXjQg4K1f7TWdypF0oDb32e5fOnzjuX4=",
      "nonce": "qrvM",
      "ciphertext": "3q2+7w",
      "tag": "EBES"
    }
    """;

    [Fact]
    public void DeserialisesAChallenge()
    {
        var message = JsonSerializer.Deserialize<PairingChallengeMessage>(ChallengeJson, ProtocolJson.Options)!;

        Assert.Equal(Guid.Parse("11111111-1111-1111-1111-111111111111"), message.ChallengeId);
        Assert.Equal("550e8400-e29b-41d4-a716-446655440000", message.InitiatorDeviceId);
        Assert.Equal("Test PC", message.InitiatorDeviceName);
        Assert.Equal(32, message.InitiatorPublicKey.Length);
        Assert.Equal(new byte[] { 0xDE, 0xAD, 0xBE, 0xEF }, message.Ciphertext);
    }

    [Fact]
    public void WritesTheChallengeIdInLowercase()
    {
        // Android generates lowercase challenge ids and compares them as
        // strings; the macOS models carry explicit comments about this.
        var message = new PairingChallengeMessage
        {
            ChallengeId = Guid.Parse("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            InitiatorDeviceId = "550e8400-e29b-41d4-a716-446655440000",
            InitiatorDeviceName = "Test PC",
            InitiatorPublicKey = new byte[32],
            Nonce = new byte[12],
            Ciphertext = [0x01],
            Tag = new byte[16],
        };

        var json = JsonSerializer.Serialize(message, ProtocolJson.Options);

        Assert.Contains("\"challenge_id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void TheAckCarriesNoResponderPublicKey()
    {
        // Protocol section 9.2 claims otherwise. The shipping ACK has six
        // fields and none of them is a key; the responder publishes its key
        // before the challenge instead. A client waiting for one here waits
        // forever.
        Assert.Null(typeof(PairingAckMessage).GetProperty("ResponderPublicKey"));

        var json = JsonSerializer.Serialize(
            new PairingAckMessage
            {
                ChallengeId = Guid.NewGuid(),
                ResponderDeviceId = Guid.NewGuid(),
                ResponderDeviceName = "Peer",
                Nonce = new byte[12],
                Ciphertext = [0x01],
                Tag = new byte[16],
            },
            ProtocolJson.Options);

        Assert.DoesNotContain("pub_key", json, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RoundTripsTheChallengePayload()
    {
        var payload = new PairingChallengePayload
        {
            Challenge = [0x01, 0x02, 0x03],
            Timestamp = DateTimeOffset.Parse("2026-08-29T12:00:00Z"),
        };

        var json = JsonSerializer.Serialize(payload, ProtocolJson.Options);
        var back = JsonSerializer.Deserialize<PairingChallengePayload>(json, ProtocolJson.Options)!;

        Assert.Equal(payload.Challenge, back.Challenge);
        Assert.Equal(payload.Timestamp, back.Timestamp);
        Assert.Contains("\"timestamp\":\"2026-08-29T12:00:00Z\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void TheAckPayloadUsesSnakeCaseFieldNames()
    {
        var payload = new PairingAckPayload
        {
            ResponseHash = new byte[32],
            IssuedAt = DateTimeOffset.Parse("2026-08-29T12:00:00Z"),
        };

        var json = JsonSerializer.Serialize(payload, ProtocolJson.Options);

        Assert.Contains("response_hash", json, StringComparison.Ordinal);
        Assert.Contains("issued_at", json, StringComparison.Ordinal);
    }
}
