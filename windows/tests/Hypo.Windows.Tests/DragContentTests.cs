using System.Text;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class DragContentTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-drag").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private static ClipboardContent Content(ContentType type, byte[] data, string? fileName = null) => new()
    {
        ContentType = type,
        Data = data,
        Metadata = fileName is null ? null : new Dictionary<string, string> { ["file_name"] = fileName },
    };

    [Theory]
    [InlineData(ContentType.Text)]
    [InlineData(ContentType.Link)]
    public void TextGoesAsText(ContentType type)
    {
        var payload = DragContent.For(Content(type, Encoding.UTF8.GetBytes("something to drop")), _dir);

        Assert.Equal("something to drop", payload.Text);
        Assert.Null(payload.Files);
        Assert.True(payload.HasAnything);
    }

    [Fact]
    public void AnImageGoesAsPngBytes()
    {
        var payload = DragContent.For(Content(ContentType.Image, [137, 80, 78, 71]), _dir);

        Assert.Equal<byte[]>([137, 80, 78, 71], payload.Png!);
        Assert.Null(payload.Text);
    }

    [Fact]
    public void AFileIsWrittenToDiskBeforeTheDragBegins()
    {
        // A drop target receives a path, not bytes, so the file has to exist by
        // the time anything can be dropped on.
        var payload = DragContent.For(
            Content(ContentType.File, Encoding.UTF8.GetBytes("%PDF-1.7"), "report.pdf"), _dir);

        var path = Assert.Single(payload.Files!);

        Assert.True(File.Exists(path));
        Assert.Equal("%PDF-1.7", File.ReadAllText(path));
        Assert.Equal("report.pdf", Path.GetFileName(path));

        // The name too: a target that cannot take a file still gets something
        // rather than refusing the drop outright.
        Assert.Equal("report.pdf", payload.Text);
    }

    [Fact]
    public void DraggingTheSameFileTwiceDoesNotOverwriteTheFirst()
    {
        var content = Content(ContentType.File, Encoding.UTF8.GetBytes("first"), "report.pdf");

        var first = DragContent.For(content, _dir).Files![0];
        var second = DragContent.For(
            Content(ContentType.File, Encoding.UTF8.GetBytes("second"), "report.pdf"), _dir).Files![0];

        Assert.NotEqual(first, second);
        Assert.Equal("first", File.ReadAllText(first));
        Assert.Equal("second", File.ReadAllText(second));
    }

    [Fact]
    public void APeerSuppliedNameCannotChooseWhereTheFileLands()
    {
        var payload = DragContent.For(
            Content(ContentType.File, [1], @"..\..\autorun.inf"), _dir);

        var path = Assert.Single(payload.Files!);

        // The name comes from another device. It becomes a filename, not a
        // traversal.
        Assert.Equal(Path.GetFullPath(_dir), Path.GetFullPath(Path.GetDirectoryName(path)!));
        Assert.DoesNotContain("..", Path.GetFileName(path), StringComparison.Ordinal);
    }

    [Fact]
    public void AContentTypeThisClientCannotDragStartsNoDrag()
    {
        var payload = DragContent.For(Content((ContentType)999, [1, 2, 3]), _dir);

        Assert.False(payload.HasAnything);
    }

    [Fact]
    public void DraggedFilesGoToTempRatherThanTheReceivedFolder()
    {
        // A copy made for a drop is not something a peer sent, and should not
        // pile up somewhere the user thinks of as theirs.
        Assert.Equal(
            Path.Combine(Path.GetTempPath(), "Hypo"),
            DragContent.DefaultTemporaryDirectory);
    }
}
