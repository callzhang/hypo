using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Hypo.Core.Crypto;
using Hypo.Core.Protocol;
using Hypo.Core.Utils;

namespace Hypo.Core.Tests;

public class PayloadPipelineTests
{
    private const string DeviceId = "550e8400-e29b-41d4-a716-446655440000";

    [Fact]
    public void SerialiseCompressEncryptFrameRoundTrips()
    {
        // CryptoService.Encrypt requires a CSPRNG-sourced nonce that is never
        // reused under one key; this test is the shape Plan 2 will copy.
        var key = new byte[CryptoService.KeySizeBytes];
        var nonce = new byte[CryptoService.NonceSizeBytes];
        RandomNumberGenerator.Fill(key);
        RandomNumberGenerator.Fill(nonce);

        var timestamp = DateTimeOffset.Parse("2026-08-28T12:00:00Z");
        var original = new ClipboardPayload
        {
            ContentType = ContentType.Text,
            Data = Encoding.UTF8.GetBytes("Copied on Windows, pasted on macOS."),
            Compressed = true,
        };

        // Outbound: serialise, gzip, encrypt, frame.
        var json = JsonSerializer.SerializeToUtf8Bytes(original, ProtocolJson.Options);
        var compressed = GzipCompressor.Compress(json);
        var aad = CryptoService.BuildAssociatedData(DeviceId);
        var (ciphertext, tag) = CryptoService.Encrypt(compressed, key, nonce, aad);

        var frame = new TransportFrameCodec().Encode(new SyncEnvelope
        {
            Id = Guid.NewGuid(),
            Timestamp = timestamp,
            Type = MessageType.Clipboard,
            Payload = new EnvelopePayload
            {
                ContentType = ContentType.Text,
                Ciphertext = ciphertext,
                DeviceId = DeviceId,
                DevicePlatform = "windows",
                DeviceName = "Test PC",
                Encryption = new EncryptionMetadata { Nonce = nonce, Tag = tag },
            },
        });

        // Inbound: unframe, decrypt, gunzip, deserialise.
        var envelope = new TransportFrameCodec().Decode(frame);
        var recoveredAad = CryptoService.BuildAssociatedData(envelope.Payload.DeviceId);
        var decrypted = CryptoService.Decrypt(
            envelope.Payload.Ciphertext,
            key,
            envelope.Payload.Encryption.Nonce,
            envelope.Payload.Encryption.Tag,
            recoveredAad);
        var decompressed = GzipCompressor.Decompress(decrypted);
        var recovered = JsonSerializer.Deserialize<ClipboardPayload>(decompressed, ProtocolJson.Options)!;

        Assert.Equal(original.Data, recovered.Data);
        Assert.Equal(original.ContentType, recovered.ContentType);
        Assert.True(recovered.Compressed);
        Assert.Equal("windows", envelope.Payload.DevicePlatform);
    }

    [Fact]
    public void AssociatedDataIgnoresDeviceIdCasing()
    {
        Assert.Equal(
            CryptoService.BuildAssociatedData(DeviceId),
            CryptoService.BuildAssociatedData(DeviceId.ToUpperInvariant()));
    }
}
