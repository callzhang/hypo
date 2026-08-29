using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>Clipboard content types. Protocol section 3.2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ContentType>))]
public enum ContentType
{
    [JsonStringEnumMemberName("text")] Text,
    [JsonStringEnumMemberName("link")] Link,
    [JsonStringEnumMemberName("image")] Image,
    [JsonStringEnumMemberName("file")] File,
}

/// <summary>Envelope message types. Protocol section 2.1.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<MessageType>))]
public enum MessageType
{
    [JsonStringEnumMemberName("clipboard")] Clipboard,
    [JsonStringEnumMemberName("control")] Control,
    [JsonStringEnumMemberName("error")] Error,
}

/// <summary>
/// The single serializer configuration used for every protocol message.
/// Snake case matches the macOS codec's convertToSnakeCase strategy and the
/// Android client's field names.
/// </summary>
public static class ProtocolJson
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
}
