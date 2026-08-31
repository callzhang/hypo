using System.IO;
using System.Text;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.App;
using Hypo.Windows.App.Shell;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// The windows at the display scalings people actually use.
///
/// <para>"We cannot test DPI here" was true of a second monitor and false of
/// everything else: WPF renders at whatever DPI it is asked for, so a layout
/// that only holds together at 100% can be caught on one machine.</para>
/// </summary>
[Collection("wpf")]
public class ScalingTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-dpi").FullName;
    private readonly ClipboardHistoryStore _history;

    public ScalingTests()
    {
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));

        // Content long enough that clipping or overflow would show.
        _history.Add(new HistoryEntry
        {
            Content = new ClipboardContent
            {
                ContentType = ContentType.Text,
                Data = Encoding.UTF8.GetBytes(
                    "A clipboard entry long enough that a layout which only works at 100% "
                    + "will visibly run out of room somewhere"),
            },
            CopiedAt = DateTimeOffset.UnixEpoch.AddMinutes(2),
        });
        _history.Add(new HistoryEntry
        {
            Content = new ClipboardContent
            {
                ContentType = ContentType.Text,
                Data = Encoding.UTF8.GetBytes("你好,剪贴板 — mixed scripts and emoji 🎉"),
            },
            CopiedAt = DateTimeOffset.UnixEpoch.AddMinutes(1),
        });
    }

    public void Dispose()
    {
        _history.Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    private sealed class NullClipboard : IClipboard
    {
        public event EventHandler<ClipboardContent>? ContentChanged;

        public Task<ClipboardContent?> GetAsync(CancellationToken ct = default)
        {
            _ = ContentChanged;
            return Task.FromResult<ClipboardContent?>(null);
        }

        public Task SetAsync(ClipboardContent content, CancellationToken ct = default) => Task.CompletedTask;
    }

    [SkippableTheory]
    [InlineData(96, "100")]
    [InlineData(144, "150")]
    [InlineData(192, "200")]
    public void TheHistoryWindowRendersAtEveryCommonScaling(double dpi, string label)
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var model = new HistoryViewModel(_history, new NullClipboard());
            model.Refresh();

            var window = new HistoryWindow(model);
            window.Show();
            window.Settle();

            var pixels = window.Capture($"history-window-{label}pc", dpi);

            Assert.True(Wpf.HasVisibleContent(pixels), $"blank at {label}%");

            // The list must still be showing its rows: a layout that collapsed
            // under scaling renders content somewhere and shows nothing useful.
            var list = (System.Windows.Controls.ListBox)window.FindName("Rows");
            Assert.Equal(2, list.Items.Count);
            Assert.True(window.ActualWidth > 300, $"width collapsed to {window.ActualWidth} at {label}%");

            window.Close();
        });
    }

    [SkippableFact]
    public void TheHintStaysReadableWhenTheHistoryIsEmpty()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        using var empty = new ClipboardHistoryStore(Path.Combine(_dir, "empty.db"));

        Wpf.Run(() =>
        {
            var model = new HistoryViewModel(empty, new NullClipboard());
            model.Refresh();

            var window = new HistoryWindow(model);
            window.Show();

            var pixels = window.Capture("history-window-empty-200pc", 192);
            Assert.True(Wpf.HasVisibleContent(pixels), "blank at 200%");

            window.Close();
        });
    }

    [SkippableTheory]
    [InlineData(96, "100")]
    [InlineData(192, "200")]
    public void ALongEntryIsTrimmedRatherThanPushingAScrollbarUnderEverything(double dpi, string label)
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // Found by looking at a 200% screenshot: the list was growing to fit its
        // longest entry, so TextTrimming had nothing to trim to, the ellipsis
        // never appeared, and a horizontal scrollbar sat under the whole list.
        Wpf.Run(() =>
        {
            var model = new HistoryViewModel(_history, new NullClipboard());
            model.Refresh();

            var window = new HistoryWindow(model);
            window.Show();
            window.Settle();

            var list = (System.Windows.Controls.ListBox)window.FindName("Rows");

            var scroller = FindScrollViewer(list);
            Assert.NotNull(scroller);
            Assert.Equal(0, scroller!.ScrollableWidth);
            Assert.True(list.ActualWidth <= window.ActualWidth, "the list is wider than its window");

            window.Capture($"history-window-trimmed-{label}pc", dpi);
            window.Close();
        });
    }

    private static System.Windows.Controls.ScrollViewer? FindScrollViewer(System.Windows.DependencyObject root)
    {
        if (root is System.Windows.Controls.ScrollViewer found)
        {
            return found;
        }

        var children = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);

        for (var i = 0; i < children; i++)
        {
            if (FindScrollViewer(System.Windows.Media.VisualTreeHelper.GetChild(root, i)) is { } scroller)
            {
                return scroller;
            }
        }

        return null;
    }
}
