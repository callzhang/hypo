using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>
/// Serialises byte arrays as base64 strings, accepting unpadded input on read.
/// </summary>
public sealed class Base64ByteArrayConverter : JsonConverter<byte[]>
{
    /// <summary>
    /// Reference-type converters are not invoked for null tokens unless this is
    /// true, so a JSON null would bypass Read and assign null to the property.
    /// </summary>
    public override bool HandleNull => true;

    public override byte[] Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null)
        {
            return [];
        }

        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException($"Expected a base64 string but found {reader.TokenType}.");
        }

        // This try/catch is load-bearing, not redundant. System.Text.Json only
        // auto-wraps FormatException into JsonException when its own reader
        // methods throw it (Utf8JsonReader.GetDateTimeOffset and friends).
        // Convert.FromBase64String is user code on this path, and STJ does not
        // wrap arbitrary exceptions raised by a converter body: removing the
        // catch was measured to let a bare FormatException escape
        // JsonSerializer.Deserialize, which is what
        // ThrowsJsonExceptionOnMalformedBase64 guards against.
        try
        {
            return Base64Compat.Decode(reader.GetString()!);
        }
        catch (FormatException ex)
        {
            // This converter decodes untrusted peer data, and callers at the
            // deserialization boundary catch JsonException to drop a malformed
            // message. A raw FormatException would slip past those handlers.
            // System.Text.Json fills in Path and LineNumber on the way out.
            throw new JsonException("Expected a valid base64 string.", ex);
        }
    }

    public override void Write(Utf8JsonWriter writer, byte[] value, JsonSerializerOptions options)
    {
        // WriteStringValue would escape '+' as a \u002B sequence under the
        // default encoder; WriteBase64StringValue emits the alphabet verbatim.
        writer.WriteBase64StringValue(value);
    }
}
