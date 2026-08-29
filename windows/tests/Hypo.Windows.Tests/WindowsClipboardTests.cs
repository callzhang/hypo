using System.Diagnostics;
using System.Text;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows.Tests;

/// <summary>
/// These touch the machine's real clipboard, so they must not run at the same
/// time as each other: two tests opening it concurrently is precisely the
/// contention the retry exists for, and letting them race would make the suite
/// flaky in a way that teaches nothing.
/// </summary>
[Collection("clipboard")]
public class WindowsClipboardTests
{
    /// <summary>
    /// These drive real Win32 calls. net10.0-windows does not stop them running
    /// elsewhere -- SupportedOSPlatform is an analyser annotation, not a runtime
    /// gate -- so the gate has to be here, or the whole suite goes red on the
    /// machine most of the development happens on.
    /// </summary>
    private static void RequireWindows() =>
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only: drives the real Win32 clipboard.");

    [SkippableFact]
    public void ReadsBackWhatItWrote()
    {
        RequireWindows();
        WindowsClipboard.WriteText("round trip");

        Assert.Equal("round trip", WindowsClipboard.ReadText());
    }

    [SkippableTheory]
    [InlineData("你好，剪贴板")]
    [InlineData("emoji 🎉 mixed with 中文")]
    public void PreservesNonAsciiText(string text)
    {
        RequireWindows();
        // CF_TEXT would return question marks here. This is the test that keeps
        // the CJK Plan 3 got across the wire from being lost at the last step.
        WindowsClipboard.WriteText(text);

        Assert.Equal(text, WindowsClipboard.ReadText());
    }

    [SkippableFact]
    public void HandlesAMegabyte()
    {
        RequireWindows();
        var large = new string('x', 1024 * 1024);

        WindowsClipboard.WriteText(large);

        Assert.Equal(large, WindowsClipboard.ReadText());
    }

    [SkippableFact]
    public void EmptyTextRoundTrips()
    {
        RequireWindows();
        WindowsClipboard.WriteText(string.Empty);

        Assert.Equal(string.Empty, WindowsClipboard.ReadText());
    }

    [SkippableFact]
    public void RepeatedWritesDoNotLeakHandles()
    {
        RequireWindows();
        // Global memory handed to SetClipboardData belongs to the clipboard; a
        // write path that also freed it, or that failed to free on the error
        // path, shows up here rather than as a slow leak in production.
        WindowsClipboard.WriteText("warm up");
        using var process = Process.GetCurrentProcess();
        process.Refresh();
        var before = process.HandleCount;

        for (var i = 0; i < 300; i++)
        {
            WindowsClipboard.WriteText($"iteration {i}");
        }

        process.Refresh();
        var after = process.HandleCount;

        Assert.Equal($"iteration 299", WindowsClipboard.ReadText());
        Assert.True(after - before < 100, $"handle count grew from {before} to {after}");
    }

    [SkippableFact]
    public void TheSequenceNumberAdvancesOnEveryWrite()
    {
        RequireWindows();
        // The listener's echo suppression is built on this. If it did not
        // advance, our own writes would be indistinguishable from a peer's.
        var first = WindowsClipboard.WriteText("one");
        var second = WindowsClipboard.WriteText("two");

        Assert.NotEqual(first, second);
    }
}

[CollectionDefinition("clipboard", DisableParallelization = true)]
public class ClipboardCollection;
