using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// Runs WPF work on an STA thread and captures what it drew.
///
/// <para>A GitHub-hosted windows-latest runner turns out to be a fully
/// interactive session: it will show windows, create a notification-area icon,
/// and let a bitmap be captured. This project's documentation asserted the
/// opposite for several plans without ever measuring it, which is why the
/// interface went untested for as long as it did.</para>
/// </summary>
internal static class Wpf
{
    /// <summary>
    /// Where screenshots land. CI uploads this, which is the only way anyone
    /// without a Windows machine sees the interface at all.
    /// </summary>
    public static string ScreenshotDirectory { get; } = Path.Combine(
        Environment.GetEnvironmentVariable("HYPO_SCREENSHOT_DIR")
            ?? Path.Combine(AppContext.BaseDirectory, "screenshots"));

    private static readonly Lazy<Dispatcher> Ui = new(StartUiThread, LazyThreadSafetyMode.ExecutionAndPublication);

    /// <summary>
    /// Runs <paramref name="action"/> on the one STA thread all WPF tests share.
    ///
    /// <para>One thread, not one per test. <c>Application.Current</c> is
    /// process-wide and belongs to whichever thread created it, so a second
    /// thread touching anything it owns fails with "a different thread owns
    /// it" -- which is what happens the moment a test asks the application
    /// what windows are open.</para>
    /// </summary>
    public static void Run(Action action)
    {
        Exception? failure = null;

        Ui.Value.Invoke(() =>
        {
            try
            {
                action();
            }
            catch (Exception ex)
            {
                failure = ex;
            }
        }, DispatcherPriority.Normal);

        if (failure is not null)
        {
            throw failure;
        }
    }

    private static Dispatcher StartUiThread()
    {
        var ready = new TaskCompletionSource<Dispatcher>(TaskCreationOptions.RunContinuationsAsynchronously);

        var thread = new Thread(() =>
        {
            var application = System.Windows.Application.Current ?? new System.Windows.Application();

            // Without this the Application shuts down when a test closes the
            // last window it opened, and every test after it fails with "the
            // Application object is being shut down". The real App.xaml sets the
            // same mode, for the same reason: this is a tray application and its
            // windows come and go.
            application.ShutdownMode = ShutdownMode.OnExplicitShutdown;

            ready.SetResult(Dispatcher.CurrentDispatcher);
            Dispatcher.Run();
        })
        {
            IsBackground = true,
            Name = "hypo-wpf-tests",
        };

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        return ready.Task.GetAwaiter().GetResult();
    }

    /// <summary>
    /// Lets layout and rendering actually happen.
    ///
    /// <para>Dispatcher.Invoke from the dispatcher's own thread runs inline and
    /// processes nothing that is queued, so a window measured that way stays
    /// 0x0 and renders as a blank bitmap. Pushing a frame is what drains the
    /// queue, and there is no message pump running here to do it otherwise.</para>
    /// </summary>
    public static void Settle(this Window window)
    {
        for (var i = 0; i < 3; i++)
        {
            PumpTo(DispatcherPriority.Loaded);
            window.UpdateLayout();
            PumpTo(DispatcherPriority.Background);
        }
    }

    private static void PumpTo(DispatcherPriority priority)
    {
        var frame = new DispatcherFrame();

        Dispatcher.CurrentDispatcher.BeginInvoke(
            priority,
            new DispatcherOperationCallback(state =>
            {
                ((DispatcherFrame)state).Continue = false;
                return null;
            }),
            frame);

        Dispatcher.PushFrame(frame);
    }

    /// <summary>
    /// Renders a window to a PNG and returns the pixels for assertions.
    /// </summary>
    /// <param name="dpi">
    /// The rendering DPI. 96 is 100%; 144 is the 150% most laptops ship at and
    /// 192 is 200%. Rendering at scale is how a layout that only works at 100%
    /// gets caught without a second machine -- which is most of what "we cannot
    /// test DPI here" was hiding.
    /// </param>
    public static byte[] Capture(this Window window, string name, double dpi = 96)
    {
        window.Settle();

        var scale = dpi / 96.0;
        var width = (int)Math.Max(window.ActualWidth * scale, 1);
        var height = (int)Math.Max(window.ActualHeight * scale, 1);

        var bitmap = new RenderTargetBitmap(width, height, dpi, dpi, PixelFormats.Pbgra32);
        bitmap.Render(window);

        var encoder = new PngEncoder();
        var png = encoder.Encode(bitmap);

        Directory.CreateDirectory(ScreenshotDirectory);
        File.WriteAllBytes(Path.Combine(ScreenshotDirectory, $"{name}.png"), png);

        var pixels = new byte[width * height * 4];
        bitmap.CopyPixels(pixels, width * 4, 0);
        return pixels;
    }

    /// <summary>
    /// True when the image is not a single flat colour.
    ///
    /// <para>The check that matters: a window that failed to lay out renders as
    /// one uniform block, and every assertion about "it produced a bitmap" passes
    /// anyway.</para>
    /// </summary>
    public static bool HasVisibleContent(byte[] bgraPixels)
    {
        if (bgraPixels.Length < 8)
        {
            return false;
        }

        for (var i = 4; i < bgraPixels.Length; i += 4)
        {
            if (bgraPixels[i] != bgraPixels[0]
                || bgraPixels[i + 1] != bgraPixels[1]
                || bgraPixels[i + 2] != bgraPixels[2])
            {
                return true;
            }
        }

        return false;
    }

    private sealed class PngEncoder
    {
        public byte[] Encode(BitmapSource source)
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(source));

            using var stream = new MemoryStream();
            encoder.Save(stream);
            return stream.ToArray();
        }
    }
}
