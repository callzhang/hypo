using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>AES-GCM parameters carried alongside the ciphertext. Protocol section 3.5.</summary>
public sealed record EncryptionMetadata
{
    public const string AesGcmAlgorithm = "AES-256-GCM";

    public string Algorithm { get; init; } = AesGcmAlgorithm;

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Nonce { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Tag { get; init; }
}
