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

            // The shipped dictionary, not an approximation of it. Screenshots
            // taken without it showed dark windows full of white controls, which
            // is not what the application looks like -- and would have been a
            // convincing-looking bug report.
            application.Resources.MergedDictionaries.Add(new ResourceDictionary
            {
                Source = new Uri("pack://application:,,,/Hypo;component/Theme.xaml"),
            });

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
    public static byte[] Capture(this Window window, string? name, double dpi = 96)
    {
        window.Settle();

        // The window, sized by the window: rendering its content element instead
        // draws that element at its own offset -- a Margin of 12 puts it 12px in
        // and clips 12px off the far side. The title bar's worth of unpainted
        // pixels along the bottom is the cost of not doing that.
        var scale = dpi / 96.0;
        var width = (int)Math.Max(window.ActualWidth * scale, 1);
        var height = (int)Math.Max(window.ActualHeight * scale, 1);

        var bitmap = new RenderTargetBitmap(width, height, dpi, dpi, PixelFormats.Pbgra32);
        bitmap.Render(window);

        // A null name asks for the pixels without adding to the artifact. Tests
        // that read the bitmap rather than look at it would otherwise leave a
        // pile of near-identical images for someone to search through.
        if (name is not null)
        {
            var png = new PngEncoder().Encode(bitmap);

            Directory.CreateDirectory(ScreenshotDirectory);
            File.WriteAllBytes(Path.Combine(ScreenshotDirectory, $"{name}.png"), png);
        }

        var pixels = new byte[width * height * 4];
        bitmap.CopyPixels(pixels, width * 4, 0);
        return pixels;
    }

    /// <summary>
    /// Finds a block of light chrome in an image that should be dark.
    ///
    /// <para>The failure this catches: a control WPF styles itself — a Button, a
    /// ComboBox — that the theme forgot, which stays pale with white text on it
    /// and is unreadable. It has happened twice, and both times a person looking
    /// at a screenshot found it rather than a test.</para>
    ///
    /// <para>A block, not a bright pixel count: white text is bright and
    /// scattered, so counting pixels cannot tell text from chrome. A run of
    /// light pixels wide enough to be a control, repeated over enough rows to be
    /// its height, is chrome and nothing else. A single bright line is a
    /// separator, which is why the row count matters.</para>
    /// </summary>
    /// <param name="height">Rows to look at. The bitmap is the window's height
    /// and the content is the client area, so the last rows are unpainted.</param>
    public static bool HasLightChrome(byte[] pixels, int width, int height, int minWidth = 40, int minRows = 8)
    {
        var consecutive = 0;

        for (var y = 0; y < height; y++)
        {
            var run = 0;
            var wide = false;

            for (var x = 0; x < width; x++)
            {
                var i = ((y * width) + x) * 4;

                // Pbgra32: blue, green, red, alpha.
                var luminance = (0.0722 * pixels[i]) + (0.7152 * pixels[i + 1]) + (0.2126 * pixels[i + 2]);

                if (luminance > 150)
                {
                    if (++run >= minWidth)
                    {
                        wide = true;
                    }
                }
                else
                {
                    run = 0;
                }
            }

            consecutive = wide ? consecutive + 1 : 0;

            if (consecutive >= minRows)
            {
                return true;
            }
        }

        return false;
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
