using System.Buffers.Binary;
using System.Text;
using System.Text.Json.Nodes;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class TransportFrameCodecTests
{
    private static SyncEnvelope SampleEnvelope() => new()
    {
        Id = Guid.Parse("11111111-1111-1111-1111-111111111111"),
        Timestamp = DateTimeOffset.Parse("2025-10-03T00:00:00Z"),
        Type = MessageType.Clipboard,
        Payload = new EnvelopePayload
        {
            ContentType = ContentType.Text,
            Ciphertext = [0x01, 0x02, 0x03],
            DeviceId = "deviceA",
            Target = "deviceB",
            Encryption = new EncryptionMetadata { Nonce = [0xAA], Tag = [0xBB] },
        },
    };

    [Fact]
    public void RoundTripsAnEnvelope()
    {
        var codec = new TransportFrameCodec();

        var decoded = codec.Decode(codec.Encode(SampleEnvelope()));

        Assert.Equal("deviceA", decoded.Payload.DeviceId);
        Assert.Equal("deviceB", decoded.Payload.Target);
        Assert.Equal(new byte[] { 0x01, 0x02, 0x03 }, decoded.Payload.Ciphertext);
    }

    [Fact]
    public void WritesABigEndianLengthPrefix()
    {
        var codec = new TransportFrameCodec();

        var frame = codec.Encode(SampleEnvelope());
        var declared = BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(0, 4));

        Assert.Equal((uint)(frame.Length - 4), declared);
    }

    [Fact]
    public void DecodesTheSharedFrameVectorAndReEncodesToAnEquivalentBody()
    {
        var codec = new TransportFrameCodec();
        var vectors = JsonNode.Parse(File.ReadAllText(RepoFixtures.FrameVectorsPath))!.AsArray();
        var vector = vectors[0]!;
        var frame = Convert.FromBase64String(vector["base64"]!.GetValue<string>());
        var expectedDeviceId = vector["envelope"]!["payload"]!["device_id"]!.GetValue<string>();

        var decoded = codec.Decode(frame);
        Assert.Equal(expectedDeviceId, decoded.Payload.DeviceId);

        // Compare parsed bodies, not raw bytes: JSON key order is not part of
        // the contract and differs between Swift, Kotlin and .NET.
        var originalBody = JsonNode.Parse(Encoding.UTF8.GetString(frame, 4, frame.Length - 4))!;
        var reEncoded = codec.Encode(decoded);
        var reEncodedBody = JsonNode.Parse(Encoding.UTF8.GetString(reEncoded, 4, reEncoded.Length - 4))!;
        Assert.True(JsonNode.DeepEquals(originalBody, reEncodedBody));
    }

    [Fact]
    public void ThrowsWhenTheFrameIsShorterThanItsLengthPrefixClaims()
    {
        var codec = new TransportFrameCodec();

        var error = Assert.Throws<TransportFrameException>(
            () => codec.Decode(new byte[] { 0x00, 0x00, 0x00, 0x05, 0x01 }));

        Assert.Equal(TransportFrameError.Truncated, error.Error);
    }

    [Fact]
    public void ThrowsWhenTheFrameIsShorterThanTheLengthPrefixItself()
    {
        var codec = new TransportFrameCodec();

        var error = Assert.Throws<TransportFrameException>(() => codec.Decode(new byte[] { 0x00, 0x00 }));

        Assert.Equal(TransportFrameError.Truncated, error.Error);
    }

    [Fact]
    public void ThrowsWhenTheEncodedBodyExceedsTheConfiguredCeiling()
    {
        var codec = new TransportFrameCodec(maxPayloadBytes: 1);

        var error = Assert.Throws<TransportFrameException>(() => codec.Encode(SampleEnvelope()));

        Assert.Equal(TransportFrameError.PayloadTooLarge, error.Error);
    }
}
