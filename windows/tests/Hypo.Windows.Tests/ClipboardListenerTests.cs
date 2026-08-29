using System.Text;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows.Tests;

[Collection("clipboard")]
public class ClipboardListenerTests
{
    /// <summary>
    /// These drive real Win32 calls. net10.0-windows does not stop them running
    /// elsewhere -- SupportedOSPlatform is an analyser annotation, not a runtime
    /// gate -- so the gate has to be here, or the whole suite goes red on the
    /// machine most of the development happens on.
    /// </summary>
    private static void RequireWindows() =>
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only: drives the real Win32 clipboard.");

    private static ClipboardContent Text(string s) =>
        new() { ContentType = ContentType.Text, Data = Encoding.UTF8.GetBytes(s) };

    private static async Task<T?> WaitFor<T>(TaskCompletionSource<T> source, int seconds = 5)
    {
        try
        {
            return await source.Task.WaitAsync(TimeSpan.FromSeconds(seconds));
        }
        catch (TimeoutException)
        {
            return default;
        }
    }

    [SkippableFact]
    public async Task AWriteThroughSetAsyncRaisesNoChange()
    {
        RequireWindows();
        // The loop test, first. Windows raises WM_CLIPBOARDUPDATE for our own
        // writes exactly as for anyone else's, so without suppression, applying
        // a peer's item sends it straight back and the two devices echo forever.
        using var listener = new ClipboardListener();

        var raised = 0;
        listener.ContentChanged += (_, _) => Interlocked.Increment(ref raised);

        await listener.SetAsync(Text("applied from a peer"));
        await Task.Delay(TimeSpan.FromSeconds(1));

        Assert.Equal(0, raised);
        Assert.Equal("applied from a peer", WindowsClipboard.ReadText());
    }

    [SkippableFact]
    public async Task AnExternalWriteRaisesExactlyOneChange()
    {
        RequireWindows();
        using var listener = new ClipboardListener();

        var seen = new TaskCompletionSource<ClipboardContent>(TaskCreationOptions.RunContinuationsAsynchronously);
        var count = 0;
        listener.ContentChanged += (_, content) =>
        {
            Interlocked.Increment(ref count);
            seen.TrySetResult(content);
        };

        WindowsClipboard.WriteText("someone else copied this");

        var content = await WaitFor(seen);

        Assert.NotNull(content);
        Assert.Equal("someone else copied this", Encoding.UTF8.GetString(content!.Data));

        await Task.Delay(TimeSpan.FromMilliseconds(500));
        Assert.Equal(1, count);
    }

    [SkippableFact]
    public async Task ReportsTheLastOfARapidBurstWithoutStalling()
    {
        RequireWindows();
        // A message loop that stops draining is a hang rather than a failure,
        // so this asserts against a deadline instead of waiting forever.
        using var listener = new ClipboardListener();

        var last = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        listener.ContentChanged += (_, content) =>
        {
            if (Encoding.UTF8.GetString(content.Data) == "burst 9")
            {
                last.TrySetResult("burst 9");
            }
        };

        for (var i = 0; i < 10; i++)
        {
            WindowsClipboard.WriteText($"burst {i}");
        }

        Assert.Equal("burst 9", await WaitFor(last, seconds: 10));
    }

    [SkippableFact]
    public async Task GetAsyncReadsWhatIsThere()
    {
        RequireWindows();
        using var listener = new ClipboardListener();
        WindowsClipboard.WriteText("already on the clipboard");

        var content = await listener.GetAsync();

        Assert.NotNull(content);
        Assert.Equal("already on the clipboard", Encoding.UTF8.GetString(content!.Data));
    }

    [SkippableFact]
    public async Task StopsRaisingAfterDispose()
    {
        RequireWindows();
        // A leaked message-only window keeps the process alive, which for a
        // background sync tool means it never really quits.
        var listener = new ClipboardListener();
        var raised = 0;
        listener.ContentChanged += (_, _) => Interlocked.Increment(ref raised);

        listener.Dispose();

        WindowsClipboard.WriteText("after dispose");
        await Task.Delay(TimeSpan.FromSeconds(1));

        Assert.Equal(0, raised);
    }

    [SkippableFact]
    public async Task RefusesContentItCannotWriteYet()
    {
        RequireWindows();
        using var listener = new ClipboardListener();

        await Assert.ThrowsAsync<NotSupportedException>(() => listener.SetAsync(
            new ClipboardContent { ContentType = ContentType.Image, Data = [1, 2, 3] }));
    }
}
