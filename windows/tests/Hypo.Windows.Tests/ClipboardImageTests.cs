using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows.Tests;

[Collection("clipboard")]
public class ClipboardImageTests
{
    /// <summary>
    /// A real 2x2 RGBA PNG, inline rather than a fixture file so the test cannot
    /// be broken by a missing asset in a published build.
    /// </summary>
    private static readonly byte[] Png = Convert.FromBase64String(
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP4z8DwHwyBNBAw/AcAR8oI+ItOQ4UAAAAASUVORK5CYII=");

    private static void RequireWindows() =>
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only: drives the real Win32 clipboard.");

    /// <summary>Built rather than inlined: a real JPEG is a kilobyte of base64.</summary>
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static byte[] EncodeAsJpeg(byte[] png)
    {
        using var input = new MemoryStream(png, writable: false);
        using var image = System.Drawing.Image.FromStream(input);
        using var output = new MemoryStream();
        image.Save(output, System.Drawing.Imaging.ImageFormat.Jpeg);

        return output.ToArray();
    }

    [Fact]
    public void RecognisesThePngSignature()
    {
        Assert.True(ClipboardFormats.LooksLikePng(Png));
        Assert.False(ClipboardFormats.LooksLikePng("not a png at all"u8.ToArray()));
        Assert.False(ClipboardFormats.LooksLikePng([0x89, 0x50]));
        Assert.False(ClipboardFormats.LooksLikePng([]));
    }

    [SkippableFact]
    public void RegistersThePngFormat()
    {
        RequireWindows();

        // Zero means RegisterClipboardFormat failed, and every image operation
        // would then silently target format 0.
        Assert.NotEqual(0u, ClipboardFormats.PngFormat);
        Assert.Equal(ClipboardFormats.PngFormat, ClipboardFormats.FormatFor(ContentType.Image));
    }

    [SkippableFact]
    public void RoundTripsAPngThroughTheClipboard()
    {
        RequireWindows();

        WindowsClipboard.WritePng(Png);

        Assert.Equal(Png, WindowsClipboard.ReadPng());
    }

    [Fact]
    public void RecognisesTheJpegSignature()
    {
        Assert.True(ClipboardFormats.LooksLikeJpeg([0xFF, 0xD8, 0xFF, 0xE0]));
        Assert.False(ClipboardFormats.LooksLikeJpeg(Png));
        Assert.False(ClipboardFormats.LooksLikeJpeg([0xFF, 0xD8]));
        Assert.False(ClipboardFormats.LooksLikeJpeg([]));
    }

    /// <summary>
    /// A peer that re-encodes anything large before sending -- as the Mac does --
    /// delivers JPEG, and refusing it meant the bigger the picture, the more
    /// certainly it never arrived.
    /// </summary>
    [SkippableFact]
    public void AcceptsAPeersJpegByConvertingItToPng()
    {
        RequireWindows();

        var jpeg = EncodeAsJpeg(Png);
        Assert.True(ClipboardFormats.LooksLikeJpeg(jpeg));

        var converted = ImageCompressor.ToPng(jpeg);

        // Published as PNG because that is the format Windows applications paste;
        // nothing reads raw JPEG bytes off the clipboard.
        Assert.True(ClipboardFormats.LooksLikePng(converted));
    }

    [SkippableFact]
    public async Task PublishesAJpegFromAPeer()
    {
        RequireWindows();

        using var listener = new ClipboardListener();

        await listener.SetAsync(new ClipboardContent
        {
            ContentType = ContentType.Image,
            Data = EncodeAsJpeg(Png),
        });

        Assert.True(ClipboardFormats.LooksLikePng(WindowsClipboard.ReadPng()!));
    }

    [SkippableFact]
    public void RefusesBytesThatAreNeitherAPngNorAJpeg()
    {
        RequireWindows();

        Assert.Throws<ArgumentException>(() => WindowsClipboard.WriteImage("just text"u8.ToArray()));
    }

    [SkippableFact]
    public void RefusesBytesThatAreNotAPng()
    {
        RequireWindows();

        // Advertising these under the PNG format would make whatever pasted them
        // fail in a way that looks like our bug rather than the sender's.
        Assert.Throws<ArgumentException>(() => WindowsClipboard.WritePng("just text"u8.ToArray()));
    }

    [SkippableFact]
    public async Task PrefersTheImageWhenTextIsAlsoOnTheClipboard()
    {
        RequireWindows();

        // Applications that copy a picture usually put a filename or URL
        // alongside it; taking the text would sync the label, not the picture.
        using var listener = new ClipboardListener();

        await listener.SetAsync(new ClipboardContent { ContentType = ContentType.Image, Data = Png });

        var content = await listener.GetAsync();

        Assert.NotNull(content);
        Assert.Equal(ContentType.Image, content!.ContentType);
        Assert.Equal(Png, content.Data);
    }

    [SkippableFact]
    public async Task WritingAnImageRaisesNoChange()
    {
        RequireWindows();

        // The echo suppression has to cover images too, or applying a picture
        // from a peer sends it straight back.
        using var listener = new ClipboardListener();

        var raised = 0;
        listener.ContentChanged += (_, _) => Interlocked.Increment(ref raised);

        await listener.SetAsync(new ClipboardContent { ContentType = ContentType.Image, Data = Png });
        await Task.Delay(TimeSpan.FromSeconds(1));

        Assert.Equal(0, raised);
    }

    [SkippableFact]
    public async Task RefusesAnImageThatIsNotPng()
    {
        RequireWindows();

        using var listener = new ClipboardListener();

        await Assert.ThrowsAsync<NotSupportedException>(() => listener.SetAsync(
            new ClipboardContent { ContentType = ContentType.Image, Data = "jpeg?"u8.ToArray() }));
    }
}
