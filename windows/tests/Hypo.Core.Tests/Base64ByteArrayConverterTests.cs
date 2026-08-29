using System.Text.Json;
using System.Text.Json.Serialization;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class Base64ByteArrayConverterTests
{
    private sealed record Holder
    {
        [JsonPropertyName("value")]
        [JsonConverter(typeof(Base64ByteArrayConverter))]
        public byte[] Value { get; init; } = [];
    }

    [Fact]
    public void ReadsUnpaddedBase64()
    {
        var holder = JsonSerializer.Deserialize<Holder>("""{"value":"3q2+7w"}""");
        Assert.NotNull(holder);
        Assert.Equal(new byte[] { 0xDE, 0xAD, 0xBE, 0xEF }, holder.Value);
    }

    [Fact]
    public void WritesPaddedBase64()
    {
        var json = JsonSerializer.Serialize(new Holder { Value = [0xDE, 0xAD, 0xBE, 0xEF] });
        Assert.Equal("""{"value":"3q2+7w=="}""", json);
    }

    [Fact]
    public void ReadsJsonNullAsAnEmptyArray()
    {
        var holder = JsonSerializer.Deserialize<Holder>("""{"value":null}""");
        Assert.NotNull(holder);
        Assert.Empty(holder.Value);
    }
}
