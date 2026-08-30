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
    public async Task RefusesFilesClearlyRatherThanCorruptingThem()
    {
        RequireWindows();

        // SyncCoordinator keeps such an item in history and reports it, so the
        // message is not lost -- but it must not be written as mojibake either.
        using var listener = new ClipboardListener();

        await Assert.ThrowsAsync<NotSupportedException>(() => listener.SetAsync(
            new ClipboardContent { ContentType = ContentType.File, Data = [1, 2, 3] }));
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
