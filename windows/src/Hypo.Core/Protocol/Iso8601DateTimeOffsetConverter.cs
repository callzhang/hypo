using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>
/// Writes timestamps the way the macOS and Android clients write them: ISO 8601
/// in UTC with a "Z" designator and no fractional seconds. System.Text.Json's
/// built-in DateTimeOffset writer emits a numeric offset ("+00:00") instead,
/// which diverges from tests/transport/frame_vectors.json and from what both
/// existing clients put on the wire.
/// </summary>
public sealed class Iso8601DateTimeOffsetConverter : JsonConverter<DateTimeOffset>
{
    private const string Format = "yyyy-MM-dd'T'HH:mm:ss'Z'";

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetDateTimeOffset();

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToUniversalTime().ToString(Format, CultureInfo.InvariantCulture));
}
