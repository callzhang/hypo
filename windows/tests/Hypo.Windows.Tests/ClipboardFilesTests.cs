using System.Text;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows.Tests;

/// <summary>
/// The CF_HDROP layout is testable without a clipboard, which is most of what
/// can go subtly wrong here. Only the last few need Windows.
/// </summary>
[Collection("clipboard")]
public class ClipboardFilesTests
{
    private static void RequireWindows() =>
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only: drives the real Win32 clipboard.");

    [Fact]
    public void RoundTripsASinglePath()
    {
        var paths = ClipboardFiles.Decode(ClipboardFiles.Encode([@"C:\Users\derek\report.pdf"]));

        Assert.Equal(@"C:\Users\derek\report.pdf", Assert.Single(paths));
    }

    [Fact]
    public void RoundTripsSeveralPaths()
    {
        string[] input = [@"C:\a.txt", @"C:\b.txt", @"D:\c.txt"];

        Assert.Equal(input, ClipboardFiles.Decode(ClipboardFiles.Encode(input)));
    }

    [Fact]
    public void RoundTripsNonAsciiPaths()
    {
        // The wide form is not optional: the ANSI one mangles anything outside
        // the active code page, and a Chinese filename is exactly the case this
        // project keeps having to defend.
        string[] input = [@"C:\用户\derek\报告.pdf", @"C:\emoji 🎉\file.txt"];

        Assert.Equal(input, ClipboardFiles.Decode(ClipboardFiles.Encode(input)));
    }

    [Fact]
    public void EncodesTheWideFlagAndAHeaderOfTheRightSize()
    {
        var encoded = ClipboardFiles.Encode([@"C:\x.txt"]);

        Assert.Equal(20, ClipboardFiles.HeaderSize);
        Assert.Equal((uint)ClipboardFiles.HeaderSize, BitConverter.ToUInt32(encoded, 0));
        Assert.Equal(1, BitConverter.ToInt32(encoded, 16));
    }

    [Fact]
    public void RefusesToEncodeNothing()
    {
        Assert.Throws<ArgumentException>(() => ClipboardFiles.Encode([]));
    }

    [Theory]
    [InlineData(new byte[0])]
    [InlineData(new byte[] { 1, 2, 3 })]
    public void DecodesMalformedBuffersAsEmptyRatherThanThrowing(byte[] buffer)
    {
        // Another application's buffer is not something to trust.
        Assert.Empty(ClipboardFiles.Decode(buffer));
    }

    [Fact]
    public void DecodesAHeaderThatClaimsMoreThanTheBufferHoldsAsEmpty()
    {
        var encoded = ClipboardFiles.Encode([@"C:\x.txt"]);
        BitConverter.GetBytes(uint.MaxValue).CopyTo(encoded, 0);

        Assert.Empty(ClipboardFiles.Decode(encoded));
    }

    [Theory]
    [InlineData(@"..\..\autorun.inf", "autorun.inf")]
    [InlineData(@"C:\Windows\System32\evil.dll", "evil.dll")]
    [InlineData("/etc/passwd", "passwd")]
    [InlineData("report:2026.pdf", "report_2026.pdf")]
    [InlineData("ordinary.txt", "ordinary.txt")]
    [InlineData("has<illegal>chars?.txt", "has_illegal_chars_.txt")]
    [InlineData("trailing dots...", "trailing dots")]
    public void ReducesAPeerSuppliedNameToASafeLeaf(string proposed, string expected)
    {
        // The name arrives from another device and lands on this filesystem. The
        // rules are explicit rather than taken from Path.GetInvalidFileNameChars,
        // which answers for the host -- on Unix a backslash is an ordinary
        // character, so this test would pass while sanitising nothing.
        Assert.Equal(expected, ClipboardFiles.SafeFileName(proposed));
    }

    [Theory]
    [InlineData("CON")]
    [InlineData("nul.txt")]
    [InlineData("COM1.log")]
    public void EscapesTheReservedDeviceNames(string proposed)
    {
        // Creating one of these does not fail; it opens a device.
        Assert.StartsWith("_", ClipboardFiles.SafeFileName(proposed), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    [InlineData("..")]
    [InlineData("...")]
    [InlineData(@"C:\")]
    [InlineData("???")]
    public void FallsBackWhenThereIsNoUsableName(string? proposed)
    {
        Assert.Equal("clipboard-file", ClipboardFiles.SafeFileName(proposed));
    }

    [SkippableFact]
    public void RoundTripsPathsThroughTheRealClipboard()
    {
        RequireWindows();

        var path = Path.Combine(Path.GetTempPath(), "hypo-clipboard-test.txt");
        File.WriteAllText(path, "contents");

        WindowsClipboard.WriteFilePaths([path]);

        Assert.Equal(path, Assert.Single(WindowsClipboard.ReadFilePaths()));
    }

    [SkippableFact]
    public async Task WritesAPeersFileToDiskAndPutsItOnTheClipboard()
    {
        RequireWindows();

        var directory = Directory.CreateTempSubdirectory("hypo-received").FullName;
        try
        {
            using var listener = new ClipboardListener(directory);

            await listener.SetAsync(new ClipboardContent
            {
                ContentType = ContentType.File,
                Data = "from the phone"u8.ToArray(),
                Metadata = new Dictionary<string, string> { ["file_name"] = "notes.txt" },
            });

            var landed = Path.Combine(directory, "notes.txt");
            Assert.True(File.Exists(landed));
            Assert.Equal("from the phone", File.ReadAllText(landed));
            Assert.Equal(landed, Assert.Single(WindowsClipboard.ReadFilePaths()));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [SkippableFact]
    public async Task DoesNotOverwriteAFileAlreadyThere()
    {
        RequireWindows();

        // A peer resending "report.pdf" must not replace the one sitting there,
        // which the user may not have opened yet.
        var directory = Directory.CreateTempSubdirectory("hypo-received").FullName;
        try
        {
            File.WriteAllText(Path.Combine(directory, "report.pdf"), "the original");

            using var listener = new ClipboardListener(directory);
            await listener.SetAsync(new ClipboardContent
            {
                ContentType = ContentType.File,
                Data = "the newcomer"u8.ToArray(),
                Metadata = new Dictionary<string, string> { ["file_name"] = "report.pdf" },
            });

            Assert.Equal("the original", File.ReadAllText(Path.Combine(directory, "report.pdf")));
            Assert.Equal(2, Directory.GetFiles(directory).Length);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [SkippableFact]
    public async Task ReadsAFileFromTheClipboardWithItsName()
    {
        RequireWindows();

        var path = Path.Combine(Path.GetTempPath(), "hypo-outbound.txt");
        File.WriteAllText(path, "going to the phone");
        WindowsClipboard.WriteFilePaths([path]);

        using var listener = new ClipboardListener();
        var content = await listener.GetAsync();

        Assert.NotNull(content);
        Assert.Equal(ContentType.File, content!.ContentType);
        Assert.Equal("going to the phone", Encoding.UTF8.GetString(content.Data));
        Assert.Equal("hypo-outbound.txt", content.FileName);
    }
}
