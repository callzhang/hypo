using System.IO.Compression;

namespace Hypo.Core.Utils;

/// <summary>
/// Gzip container compression (RFC 1952), matching the macOS client's
/// Compression framework usage and Android's GZIPOutputStream. Raw deflate is
/// not interoperable with either and must not be substituted.
/// </summary>
public static class GzipCompressor
{
    public static byte[] Compress(ReadOnlySpan<byte> data)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.Optimal, leaveOpen: true))
        {
            gzip.Write(data);
        }

        return output.ToArray();
    }

    public static byte[] Decompress(ReadOnlySpan<byte> data)
    {
        using var input = new MemoryStream(data.ToArray(), writable: false);
        using var gzip = new GZipStream(input, CompressionMode.Decompress);
        using var output = new MemoryStream();
        gzip.CopyTo(output);
        return output.ToArray();
    }
}
