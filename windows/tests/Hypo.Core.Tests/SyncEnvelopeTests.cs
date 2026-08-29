using System.Text.Json;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class SyncEnvelopeTests
{
    private const string AndroidStyleJson = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "timestamp": "2025-10-03T00:00:00Z",
      "version": "1.0",
      "type": "clipboard",
      "payload": {
        "content_type": "text",
        "ciphertext": "3q2+7w",
        "device_id": "mac-device",
        "target": "android-device",
        "encryption": { "algorithm": "AES-256-GCM", "nonce": "qrvM", "tag": "EBES" }
      }
    }
    """;

    [Fact]
    public void DeserialisesAnUnpaddedAndroidStyleEnvelope()
    {
        var envelope = JsonSerializer.Deserialize<SyncEnvelope>(AndroidStyleJson, ProtocolJson.Options);

        Assert.NotNull(envelope);
        Assert.Equal(Guid.Parse("11111111-1111-1111-1111-111111111111"), envelope.Id);
        Assert.Equal("1.0", envelope.Version);
        Assert.Equal(MessageType.Clipboard, envelope.Type);
        Assert.Equal(ContentType.Text, envelope.Payload.ContentType);
        Assert.Equal(new byte[] { 0xDE, 0xAD, 0xBE, 0xEF }, envelope.Payload.Ciphertext);
        Assert.Equal("mac-device", envelope.Payload.DeviceId);
        Assert.Equal("android-device", envelope.Payload.Target);
        Assert.Equal(new byte[] { 0xAA, 0xBB, 0xCC }, envelope.Payload.Encryption.Nonce);
        Assert.Equal(new byte[] { 0x10, 0x11, 0x12 }, envelope.Payload.Encryption.Tag);
    }

    [Fact]
    public void OmitsAbsentOptionalFieldsWhenSerialising()
    {
        var envelope = new SyncEnvelope
        {
            Id = Guid.Parse("11111111-1111-1111-1111-111111111111"),
            Timestamp = DateTimeOffset.Parse("2025-10-03T00:00:00Z"),
            Type = MessageType.Clipboard,
            Payload = new EnvelopePayload
            {
                ContentType = ContentType.Text,
                Ciphertext = [0xDE, 0xAD, 0xBE, 0xEF],
                DeviceId = "mac-device",
                Encryption = new EncryptionMetadata { Nonce = [0xAA], Tag = [0xBB] },
            },
        };

        var json = JsonSerializer.Serialize(envelope, ProtocolJson.Options);

        Assert.DoesNotContain("device_platform", json);
        Assert.DoesNotContain("device_name", json);
        Assert.DoesNotContain("target", json);
        Assert.Contains("\"version\":\"1.0\"", json);
        Assert.Contains("\"algorithm\":\"AES-256-GCM\"", json);
    }

    [Fact]
    public void RoundTripsThroughJson()
    {
        var original = JsonSerializer.Deserialize<SyncEnvelope>(AndroidStyleJson, ProtocolJson.Options)!;
        var json = JsonSerializer.Serialize(original, ProtocolJson.Options);
        var again = JsonSerializer.Deserialize<SyncEnvelope>(json, ProtocolJson.Options)!;

        Assert.Equal(original.Id, again.Id);
        Assert.Equal(original.Payload.Ciphertext, again.Payload.Ciphertext);
        Assert.Equal(original.Payload.Encryption.Tag, again.Payload.Encryption.Tag);
    }

    [Theory]
    [InlineData("""{"id":"11111111-1111-1111-1111-111111111111","timestamp":"2025-10-03T00:00:00Z","version":"1.0","type":"clipboard","payload":null}""")]
    [InlineData("""{"id":"11111111-1111-1111-1111-111111111111","timestamp":"2025-10-03T00:00:00Z","version":"1.0","type":"clipboard","payload":{"content_type":"text","ciphertext":"3q2+7w","device_id":null,"encryption":{"algorithm":"AES-256-GCM","nonce":"qrvM","tag":"EBES"}}}""")]
    [InlineData("""{"id":"11111111-1111-1111-1111-111111111111","timestamp":"2025-10-03T00:00:00Z","version":"1.0","type":"clipboard","payload":{"content_type":"text","ciphertext":"3q2+7w","device_id":"mac-device","encryption":null}}""")]
    public void RejectsJsonNullOnRequiredMembers(string json)
    {
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<SyncEnvelope>(json, ProtocolJson.Options));
    }
}
