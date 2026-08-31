using Hypo.Core.Sync;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows.Tests;

public class ImageCompressorTests
{
    private static void RequireWindows() =>
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only: uses Windows imaging.");

    /// <summary>
    /// A PNG of random noise at the requested size. Noise on purpose: a flat
    /// image compresses to almost nothing, so a test built on one would never
    /// reach the size thresholds it is trying to exercise.
    /// </summary>
    private static byte[] NoisePng(int width, int height)
    {
        var raw = new byte[height * (1 + width * 4)];
        var random = new Random(7);

        for (var y = 0; y < height; y++)
        {
            var row = y * (1 + width * 4);
            raw[row] = 0;
            random.NextBytes(raw.AsSpan(row + 1, width * 4));
        }

        static byte[] Chunk(string tag, byte[] data)
        {
            var name = System.Text.Encoding.ASCII.GetBytes(tag);
            var length = System.Buffers.Binary.BinaryPrimitives.ReverseEndianness(data.Length);
            var crc = Crc32(name.Concat(data).ToArray());

            return BitConverter.GetBytes(length)
                .Concat(name)
                .Concat(data)
                .Concat(BitConverter.GetBytes(System.Buffers.Binary.BinaryPrimitives.ReverseEndianness((int)crc)))
                .ToArray();
        }

        var header = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

        var ihdr = BitConverter.GetBytes(System.Buffers.Binary.BinaryPrimitives.ReverseEndianness(width))
            .Concat(BitConverter.GetBytes(System.Buffers.Binary.BinaryPrimitives.ReverseEndianness(height)))
            .Concat(new byte[] { 8, 6, 0, 0, 0 })
            .ToArray();

        using var deflated = new MemoryStream();
        using (var zlib = new System.IO.Compression.ZLibStream(
            deflated, System.IO.Compression.CompressionLevel.Fastest, leaveOpen: true))
        {
            zlib.Write(raw);
        }

        return header
            .Concat(Chunk("IHDR", ihdr))
            .Concat(Chunk("IDAT", deflated.ToArray()))
            .Concat(Chunk("IEND", []))
            .ToArray();
    }

    private static uint Crc32(byte[] data)
    {
        var crc = 0xFFFFFFFFu;

        foreach (var b in data)
        {
            crc ^= b;
            for (var i = 0; i < 8; i++)
            {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
            }
        }

        return ~crc;
    }

    [SkippableFact]
    public void LeavesASmallImageExactlyAsItFoundIt()
    {
        RequireWindows();

        var png = NoisePng(64, 64);

        var result = ImageCompressor.Fit(png);

        Assert.True(result.Unchanged);
        Assert.Equal(png, result.Data);
        Assert.False(result.Refused);
    }

    [SkippableFact]
    public void ShrinksAScreenshotSizedImageUntilItFits()
    {
        RequireWindows();

        // Noise at 4K: several megabytes of PNG that no amount of lossless
        // encoding will bring under the ceiling.
        var png = NoisePng(3840, 2160);
        Skip.If(png.Length <= ImageBudget.CompressAboveBytes, "the fixture did not exceed the threshold");

        var result = ImageCompressor.Fit(png);

        Assert.False(result.Refused);
        Assert.False(result.Unchanged);
        Assert.True(ImageBudget.Fits(result.Data.Length), $"{result.Data.Length} bytes still over");
        Assert.True(result.Data.Length < png.Length);
    }

    [SkippableFact]
    public void WhatItProducesIsStillAnImage()
    {
        RequireWindows();

        // Producing bytes of the right size that no peer can decode would be
        // worse than refusing.
        var png = NoisePng(3840, 2160);
        Skip.If(png.Length <= ImageBudget.CompressAboveBytes, "the fixture did not exceed the threshold");

        var result = ImageCompressor.Fit(png);

        using var stream = new MemoryStream(result.Data);
        using var decoded = System.Drawing.Image.FromStream(stream);

        Assert.True(decoded.Width > 0 && decoded.Height > 0);
        Assert.True(Math.Max(decoded.Width, decoded.Height) <= ImageBudget.MaxLongestSide);
    }

    [SkippableFact]
    public void PassesThroughSomethingItCannotDecode()
    {
        RequireWindows();

        // A format we do not handle may still be one the peer does. Refusing on
        // our own inability to read it would be worse than not looking.
        var notAnImage = "this is not an image at all"u8.ToArray();

        var result = ImageCompressor.Fit(notAnImage);

        Assert.True(result.Unchanged);
        Assert.Equal(notAnImage, result.Data);
    }
}
