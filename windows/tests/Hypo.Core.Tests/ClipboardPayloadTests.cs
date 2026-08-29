using System.Text.Json;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class ClipboardPayloadTests
{
    [Fact]
    public void DeserialisesTheAndroidWireShape()
    {
        const string json = """
        {
          "content_type": "text",
          "data_base64": "SGVsbG8sIEh5cG8h",
          "metadata": { "size": "12", "hash": "abc" },
          "compressed": true
        }
        """;

        var payload = JsonSerializer.Deserialize<ClipboardPayload>(json, ProtocolJson.Options);

        Assert.NotNull(payload);
        Assert.Equal(ContentType.Text, payload.ContentType);
        Assert.Equal("Hello, Hypo!", System.Text.Encoding.UTF8.GetString(payload.Data));
        Assert.True(payload.Compressed);
        Assert.Equal("12", payload.Metadata!["size"]);
    }

    [Fact]
    public void SerialisesDataAsDataBase64AndNeverAsAByteArray()
    {
        var payload = new ClipboardPayload
        {
            ContentType = ContentType.Text,
            Data = System.Text.Encoding.UTF8.GetBytes("Hello, Hypo!"),
            Compressed = true,
        };

        var json = JsonSerializer.Serialize(payload, ProtocolJson.Options);

        Assert.Contains("\"data_base64\":\"SGVsbG8sIEh5cG8h\"", json);
        Assert.DoesNotContain("\"data\":", json);
        Assert.DoesNotContain("metadata", json);
    }

    [Fact]
    public void TreatsAMissingCompressedFlagAsFalse()
    {
        const string json = """{ "content_type": "file", "data_base64": "AA" }""";

        var payload = JsonSerializer.Deserialize<ClipboardPayload>(json, ProtocolJson.Options);

        Assert.NotNull(payload);
        Assert.False(payload.Compressed);
    }
}
