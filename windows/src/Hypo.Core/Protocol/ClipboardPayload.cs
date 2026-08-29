using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>
/// The plaintext document carried inside the envelope ciphertext.
/// Serialised, gzipped, then encrypted (protocol section 3.6).
/// </summary>
public sealed record ClipboardPayload
{
    public required ContentType ContentType { get; init; }

    /// <summary>
    /// The clipboard bytes. Always written as "data_base64"; the macOS client
    /// dropped the array-valued "data" field because it inflates large payloads
    /// three- to fourfold.
    /// </summary>
    [JsonPropertyName("data_base64")]
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Data { get; init; }

    public IReadOnlyDictionary<string, string>? Metadata { get; init; }

    public bool Compressed { get; init; }
}
