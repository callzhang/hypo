using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using System.Text;

namespace Hypo.Core.Tests;

public class ClipboardContentTests
{
    private static ClipboardContent Text(string s) =>
        new() { ContentType = ContentType.Text, Data = Encoding.UTF8.GetBytes(s) };

    [Fact]
    public void SameBytesAndTypeHashEqual()
    {
        Assert.True(Text("hello clipboard").HasSameContentAs(Text("hello clipboard")));
    }

    [Fact]
    public void DifferentBytesDoNot()
    {
        Assert.False(Text("hello clipboard").HasSameContentAs(Text("hello clipboards")));
    }

    [Fact]
    public void TheContentTypeIsPartOfIdentity()
    {
        // A text item and a file item that happen to share bytes are not the
        // same clipboard entry; collapsing them would silently drop the second.
        var data = Encoding.UTF8.GetBytes("/tmp/a.txt");
        var asText = new ClipboardContent { ContentType = ContentType.Text, Data = data };
        var asFile = new ClipboardContent { ContentType = ContentType.File, Data = data };

        Assert.False(asText.HasSameContentAs(asFile));
    }

    [Theory]
    // Computed independently: python3 -c "import hashlib; print(hashlib.sha256(s.encode()).hexdigest()[:16])"
    [InlineData("hello clipboard", "65b2b576750477c2")]
    [InlineData("duplicate probe with ids visible", "322bf1e8b89ff0ae")]
    public void LogHashMatchesWhatAndroidPrints(string content, string expected)
    {
        Assert.Equal(expected, Text(content).LogHash);
    }

    [Fact]
    public void LogHashIgnoresTheContentType()
    {
        // Android hashes the content bytes alone, so ours must too or the two
        // logs stop lining up -- which is the only reason this value exists.
        var data = Encoding.UTF8.GetBytes("shared");

        Assert.Equal(
            new ClipboardContent { ContentType = ContentType.Text, Data = data }.LogHash,
            new ClipboardContent { ContentType = ContentType.Image, Data = data }.LogHash);
    }

    [Fact]
    public void HashIsStableForEqualContentBuiltSeparately()
    {
        // Nothing process-specific may leak in: a hash reseeded per run would
        // make a persisted history's dedup useless after every restart.
        var a = Text("stable");
        var b = new ClipboardContent { ContentType = ContentType.Text, Data = Encoding.UTF8.GetBytes("stable") };

        Assert.Equal(Convert.ToHexString(a.Hash), Convert.ToHexString(b.Hash));
    }

    [Fact]
    public void EmptyContentIsStillIdentifiable()
    {
        var empty = new ClipboardContent { ContentType = ContentType.Text, Data = [] };

        Assert.NotEmpty(empty.Hash);
        Assert.True(empty.HasSameContentAs(
            new ClipboardContent { ContentType = ContentType.Text, Data = [] }));
    }
}
