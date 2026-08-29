using System.Text;
using Hypo.Core.Protocol;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows.Tests;

public class ClipboardFormatsTests
{
    [Theory]
    [InlineData("hello")]
    [InlineData("你好，剪贴板")]
    [InlineData("emoji 🎉 and 中文 mixed")]
    [InlineData("")]
    public void RoundTripsUnicodeText(string text)
    {
        // Encoding is where this breaks, and it breaks silently: CF_TEXT would
        // turn every one of these non-ASCII cases into question marks.
        var encoded = ClipboardFormats.EncodeUnicodeText(text);

        Assert.Equal(text, ClipboardFormats.DecodeUnicodeText(encoded));
    }

    [Fact]
    public void DecodingStopsAtTheTerminatorRatherThanAppendingIt()
    {
        // Taking the whole buffer appends a stray NUL that travels to the peer
        // and shows up as a phantom character in its history.
        var buffer = Encoding.Unicode.GetBytes("visible\0hidden");

        Assert.Equal("visible", ClipboardFormats.DecodeUnicodeText(buffer));
    }

    [Fact]
    public void DecodingToleratesAMissingTerminator()
    {
        Assert.Equal("no terminator", ClipboardFormats.DecodeUnicodeText(
            Encoding.Unicode.GetBytes("no terminator")));
    }

    [Theory]
    [InlineData("https://example.com/page")]
    [InlineData("http://example.com")]
    [InlineData("mailto:someone@example.com")]
    public void RecognisesLinks(string text)
    {
        Assert.Equal(ContentType.Link, ClipboardFormats.ClassifyText(text));
    }

    [Theory]
    [InlineData("C:\\Users\\derek\\notes.txt")]
    [InlineData("just some words")]
    [InlineData("example.com")]
    [InlineData("https://example.com\nplus a second line")]
    [InlineData("")]
    public void EverythingElseIsText(string text)
    {
        // C:\Users parses as an absolute file: URI, so a naive
        // Uri.IsWellFormedUriString check would call a Windows path a link --
        // mislabelling a large share of everything anyone copies on Windows.
        Assert.Equal(ContentType.Text, ClipboardFormats.ClassifyText(text));
    }

    [Fact]
    public void FromTextCarriesUtf8BytesAndTheClassification()
    {
        var content = ClipboardFormats.FromText("https://example.com");

        Assert.Equal(ContentType.Link, content.ContentType);
        Assert.Equal("https://example.com", Encoding.UTF8.GetString(content.Data));
    }

    [Fact]
    public void MapsContentTypesToFormats()
    {
        Assert.Equal(ClipboardFormats.CfUnicodeText, ClipboardFormats.FormatFor(ContentType.Text));
        Assert.Equal(ClipboardFormats.CfUnicodeText, ClipboardFormats.FormatFor(ContentType.Link));
        Assert.Equal(ClipboardFormats.CfHdrop, ClipboardFormats.FormatFor(ContentType.File));
    }
}
