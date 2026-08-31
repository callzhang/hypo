using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.Versioning;
using Hypo.Core.Sync;

namespace Hypo.Windows.Clipboard;

/// <summary>What came back from trying to shrink an image.</summary>
public sealed record CompressedImage
{
    public required byte[] Data { get; init; }

    /// <summary>True when the bytes were left exactly as they arrived.</summary>
    public required bool Unchanged { get; init; }

    /// <summary>Set when nothing worked, in words worth showing someone.</summary>
    public string? Refusal { get; init; }

    public bool Refused => Refusal is not null;
}

/// <summary>
/// Carries out an <see cref="ImageBudget"/> plan.
///
/// <para>The decisions live in <c>Hypo.Core</c>; this is the part that needs
/// Windows imaging, and it does as little thinking as possible.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public static class ImageCompressor
{
    public static CompressedImage Fit(byte[] image)
    {
        ArgumentNullException.ThrowIfNull(image);

        Size size;
        try
        {
            size = Measure(image);
        }
        catch (Exception ex) when (ex is ArgumentException or OutOfMemoryException)
        {
            // System.Drawing throws these for anything it cannot decode, which
            // includes a format we simply do not handle. Passing it through
            // unchanged is right: the peer may well understand it, and refusing
            // on our inability to read it would be worse than not looking.
            return new CompressedImage { Data = image, Unchanged = true };
        }

        var plan = ImageBudget.Plan(image.Length, size.Width, size.Height);

        return plan.Action switch
        {
            ImageAction.SendAsIs => new CompressedImage { Data = image, Unchanged = true },
            ImageAction.Refuse => new CompressedImage
            {
                Data = image,
                Unchanged = true,
                Refusal = plan.Reason,
            },
            _ => Compress(image, plan),
        };
    }

    private static Size Measure(byte[] image)
    {
        using var stream = new MemoryStream(image, writable: false);
        using var bitmap = Image.FromStream(stream, useEmbeddedColorManagement: false, validateImageData: false);

        return new Size(bitmap.Width, bitmap.Height);
    }

    private static CompressedImage Compress(byte[] image, ImagePlan plan)
    {
        using var stream = new MemoryStream(image, writable: false);
        using var original = Image.FromStream(stream);
        using var scaled = plan.LongestSide is { } longest ? ScaleTo(original, longest) : null;

        var source = scaled ?? original;

        foreach (var quality in plan.Qualities)
        {
            var encoded = EncodeJpeg(source, quality);

            if (ImageBudget.Fits(encoded.Length))
            {
                return new CompressedImage { Data = encoded, Unchanged = false };
            }
        }

        return new CompressedImage
        {
            Data = image,
            Unchanged = true,
            Refusal =
                $"The image is {image.Length / (1024 * 1024)} MB and would not fit even at the "
                + $"lowest quality this will use ({plan.Qualities[^1]}%).",
        };
    }

    private static Bitmap ScaleTo(Image image, int longestSide)
    {
        var scale = (double)longestSide / Math.Max(image.Width, image.Height);
        var width = Math.Max(1, (int)Math.Round(image.Width * scale));
        var height = Math.Max(1, (int)Math.Round(image.Height * scale));

        var scaled = new Bitmap(width, height);

        using var graphics = Graphics.FromImage(scaled);

        // A screenshot of text is the common case, and the cheaper modes turn
        // small type into porridge.
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        graphics.SmoothingMode = SmoothingMode.HighQuality;
        graphics.DrawImage(image, 0, 0, width, height);

        return scaled;
    }

    private static byte[] EncodeJpeg(Image image, int quality)
    {
        var codec = ImageCodecInfo.GetImageEncoders()
            .First(encoder => encoder.FormatID == ImageFormat.Jpeg.Guid);

        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(Encoder.Quality, (long)quality);

        using var output = new MemoryStream();
        image.Save(output, codec, parameters);

        return output.ToArray();
    }
}
