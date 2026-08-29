using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>
/// The envelope payload. Mirrors SyncEnvelope.Payload in the macOS client.
/// DeviceId is a bare lowercase UUID with no platform prefix (protocol v1.1+).
/// </summary>
public sealed record EnvelopePayload
{
    public required ContentType ContentType { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Ciphertext { get; init; }

    public required string DeviceId { get; init; }

    public string? DevicePlatform { get; init; }

    public string? DeviceName { get; init; }

    public string? Target { get; init; }

    public required EncryptionMetadata Encryption { get; init; }
}
