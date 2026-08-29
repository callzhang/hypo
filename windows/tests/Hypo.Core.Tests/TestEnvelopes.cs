using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

internal static class TestEnvelopes
{
    public static SyncEnvelope Clipboard(string deviceId, byte[]? ciphertext = null) => new()
    {
        Id = Guid.NewGuid(),
        Timestamp = DateTimeOffset.Parse("2026-08-29T12:00:00Z"),
        Type = MessageType.Clipboard,
        Payload = new EnvelopePayload
        {
            ContentType = ContentType.Text,
            Ciphertext = ciphertext ?? [0x01, 0x02, 0x03],
            DeviceId = deviceId,
            DevicePlatform = "windows",
            Encryption = new EncryptionMetadata { Nonce = new byte[12], Tag = new byte[16] },
        },
    };
}
