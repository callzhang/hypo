using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// Finds out what a CI runner will actually let a WPF application do.
///
/// <para>The documentation for this project has been asserting that CI "has no
/// interactive desktop", which was never measured -- and the Win32 clipboard
/// tests passing there is evidence against it. This reports what works rather
/// than guessing, so the claim can be replaced with a fact either way.</para>
/// </summary>
public class RunnerCapabilityProbe
{
    [SkippableFact]
    public void ReportWhatThisMachineAllows()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        var report = new StringBuilder();
        report.AppendLine($"interactive session: {Environment.UserInteractive}");
        report.AppendLine($"session name: {Environment.GetEnvironmentVariable("SESSIONNAME") ?? "(none)"}");

        Sta(() =>
        {
            Try(report, "create Application", () =>
            {
                _ = System.Windows.Application.Current ?? new System.Windows.Application();
            });

            Try(report, "construct a Window", () =>
            {
                var window = new Window { Width = 200, Height = 100 };
                window.Content = new TextBlock { Text = "probe" };
            });

            Try(report, "measure and arrange offscreen", () =>
            {
                var window = new Window { Width = 200, Height = 100 };
                window.Measure(new System.Windows.Size(200, 100));
                window.Arrange(new Rect(0, 0, 200, 100));
            });

            Try(report, "RenderTargetBitmap a visual", () =>
            {
                var text = new TextBlock
                {
                    Text = "probe",
                    Background = System.Windows.Media.Brushes.White,
                    Width = 120,
                    Height = 40,
                };
                text.Measure(new System.Windows.Size(120, 40));
                text.Arrange(new Rect(0, 0, 120, 40));

                var bitmap = new RenderTargetBitmap(120, 40, 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(text);

                if (bitmap.PixelWidth != 120)
                {
                    throw new InvalidOperationException("unexpected bitmap size");
                }
            });

            Try(report, "Show a real window", () =>
            {
                var window = new Window { Width = 200, Height = 100, ShowInTaskbar = false };
                window.Show();
                window.Close();
            });

            Try(report, "create a NotifyIcon", () =>
            {
                using var icon = new System.Windows.Forms.NotifyIcon
                {
                    Icon = System.Drawing.SystemIcons.Application,
                    Visible = true,
                };
                icon.Visible = false;
            });

            Try(report, "capture the screen", () =>
            {
                using var bitmap = new System.Drawing.Bitmap(64, 64);
                using var graphics = System.Drawing.Graphics.FromImage(bitmap);
                graphics.CopyFromScreen(0, 0, 0, 0, new System.Drawing.Size(64, 64));
            });
        });

        // Printed rather than asserted: this exists to tell us what is possible,
        // and a probe that fails the build teaches nothing.
        Console.WriteLine("=== runner capability probe ===");
        Console.WriteLine(report.ToString());
    }

    private static void Try(StringBuilder report, string what, Action action)
    {
        try
        {
            action();
            report.AppendLine($"  OK    {what}");
        }
        catch (Exception ex)
        {
            report.AppendLine($"  FAIL  {what}: {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>WPF requires a single-threaded apartment; xunit gives us an MTA thread.</summary>
    private static void Sta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                action();
            }
            catch (Exception ex)
            {
                failure = ex;
            }
        });

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join(TimeSpan.FromMinutes(2));

        if (failure is not null)
        {
            throw failure;
        }
    }
}
