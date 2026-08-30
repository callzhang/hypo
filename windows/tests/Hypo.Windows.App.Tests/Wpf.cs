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

    /// <summary>Runs <paramref name="action"/> on an STA thread with a live dispatcher.</summary>
    public static void Run(Action action)
    {
        Exception? failure = null;

        var thread = new Thread(() =>
        {
            try
            {
                // One Application per process; a second constructor call throws.
                _ = System.Windows.Application.Current ?? new System.Windows.Application();
                action();
            }
            catch (Exception ex)
            {
                failure = ex;
            }
        });

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        if (!thread.Join(TimeSpan.FromMinutes(2)))
        {
            throw new TimeoutException("The WPF thread did not finish. A modal dialog is the usual cause.");
        }

        if (failure is not null)
        {
            throw failure;
        }
    }

    /// <summary>
    /// Lets layout and rendering happen.
    ///
    /// <para>Showing a window does not lay it out synchronously: bindings apply
    /// and measure/arrange run at Loaded priority. Capturing before that gives a
    /// blank bitmap, which is the failure mode that makes screenshot tests look
    /// flaky rather than wrong.</para>
    /// </summary>
    public static void Settle(this Window window)
    {
        for (var i = 0; i < 3; i++)
        {
            window.Dispatcher.Invoke(() => { }, DispatcherPriority.ContextIdle);
            window.UpdateLayout();
        }
    }

    /// <summary>Renders a window to a PNG and returns the pixels for assertions.</summary>
    public static byte[] Capture(this Window window, string name)
    {
        window.Settle();

        var width = (int)Math.Max(window.ActualWidth, 1);
        var height = (int)Math.Max(window.ActualHeight, 1);

        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
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
