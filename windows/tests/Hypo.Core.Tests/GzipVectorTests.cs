using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hypo.Core.Protocol;
using Hypo.Core.Utils;

namespace Hypo.Core.Tests;

public class GzipVectorTests
{
    private static JsonNode Gzip() =>
        JsonNode.Parse(File.ReadAllText(RepoFixtures.CryptoVectorsPath))!["gzip"]!;

    private static byte[] Field(string name) => Base64Compat.Decode(Gzip()[name]!.GetValue<string>());

    [Fact]
    public void DecompressesTheSharedGzipVector()
    {
        Assert.Equal(Field("plaintext_base64"), GzipCompressor.Decompress(Field("compressed_base64")));
    }

    [Fact]
    public void OwnCompressionRoundTripsToTheSharedPlaintext()
    {
        var plaintext = Field("plaintext_base64");

        Assert.Equal(plaintext, GzipCompressor.Decompress(GzipCompressor.Compress(plaintext)));
    }

    [Fact]
    public void TheSharedPlaintextIsAValidClipboardPayload()
    {
        var plaintext = GzipCompressor.Decompress(Field("compressed_base64"));

        var payload = JsonSerializer.Deserialize<ClipboardPayload>(plaintext, ProtocolJson.Options);

        Assert.NotNull(payload);
        Assert.Equal(ContentType.Text, payload.ContentType);
        Assert.True(payload.Compressed);
        Assert.Equal("Hello, Hypo!", Encoding.UTF8.GetString(payload.Data));
    }

    [Fact]
    public void ClipboardPayloadReEncodesToTheSharedPlaintext()
    {
        var plaintext = GzipCompressor.Decompress(Field("compressed_base64"));
        var payload = JsonSerializer.Deserialize<ClipboardPayload>(plaintext, ProtocolJson.Options)!;

        var reEncoded = JsonSerializer.SerializeToUtf8Bytes(payload, ProtocolJson.Options);

        Assert.True(JsonNode.DeepEquals(
            JsonNode.Parse(Encoding.UTF8.GetString(plaintext)),
            JsonNode.Parse(Encoding.UTF8.GetString(reEncoded))));
    }
}
