using System.Text.Json;
using System.Text.Json.Serialization;
using Hypo.Core.Protocol;

namespace Hypo.Core.Pairing;

/// <summary>
/// Serialises a Guid in lowercase. Android generates lowercase challenge ids and
/// compares them as strings, so a client that wrote them uppercase would fail
/// every match.
/// </summary>
public sealed class LowercaseGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Guid.Parse(reader.GetString()!);

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToLowerInvariant());
}

/// <summary>Initiator to responder. Mirrors PairingChallengeMessage on macOS.</summary>
public sealed record PairingChallengeMessage
{
    [JsonConverter(typeof(LowercaseGuidConverter))]
    public required Guid ChallengeId { get; init; }

    public required string InitiatorDeviceId { get; init; }

    public required string InitiatorDeviceName { get; init; }

    [JsonPropertyName("initiator_pub_key")]
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] InitiatorPublicKey { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Nonce { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Ciphertext { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Tag { get; init; }
}

/// <summary>
/// Responder to initiator. Deliberately carries no key: the responder published
/// its agreement public key before the challenge arrived. See the design spec
/// section 4.2.
/// </summary>
public sealed record PairingAckMessage
{
    [JsonConverter(typeof(LowercaseGuidConverter))]
    public required Guid ChallengeId { get; init; }

    [JsonConverter(typeof(LowercaseGuidConverter))]
    public required Guid ResponderDeviceId { get; init; }

    public required string ResponderDeviceName { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Nonce { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Ciphertext { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Tag { get; init; }
}

/// <summary>The plaintext inside a challenge's ciphertext.</summary>
public sealed record PairingChallengePayload
{
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Challenge { get; init; }

    public required DateTimeOffset Timestamp { get; init; }
}

/// <summary>The plaintext inside an ack's ciphertext.</summary>
public sealed record PairingAckPayload
{
    [JsonPropertyName("response_hash")]
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] ResponseHash { get; init; }

    [JsonPropertyName("issued_at")]
    public required DateTimeOffset IssuedAt { get; init; }
}
