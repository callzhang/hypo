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
}
