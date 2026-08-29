using System.Text;
using Hypo.Core.Utils;

namespace Hypo.Core.Tests;

public class GzipCompressorTests
{
    [Fact]
    public void RoundTripsText()
    {
        var original = Encoding.UTF8.GetBytes(new string('a', 5000));

        Assert.Equal(original, GzipCompressor.Decompress(GzipCompressor.Compress(original)));
    }

    [Fact]
    public void RoundTripsAnEmptyInput()
    {
        Assert.Empty(GzipCompressor.Decompress(GzipCompressor.Compress([])));
    }

    [Fact]
    public void EmitsAGzipContainerNotRawDeflate()
    {
        var compressed = GzipCompressor.Compress(Encoding.UTF8.GetBytes("hello"));

        // RFC 1952 header: magic 0x1f 0x8b, compression method 0x08 (deflate).
        Assert.Equal(0x1F, compressed[0]);
        Assert.Equal(0x8B, compressed[1]);
        Assert.Equal(0x08, compressed[2]);
    }

    [Fact]
    public void CompressesRepetitiveTextSubstantially()
    {
        var original = Encoding.UTF8.GetBytes(new string('a', 10000));

        Assert.True(GzipCompressor.Compress(original).Length < original.Length / 10);
    }

    [Fact]
    public void ThrowsOnInputThatIsNotGzip()
    {
        Assert.ThrowsAny<Exception>(() => GzipCompressor.Decompress([0x00, 0x01, 0x02, 0x03]));
    }
}
