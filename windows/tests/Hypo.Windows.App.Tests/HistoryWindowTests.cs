using System.IO;
using System.Text;
using System.Windows;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.App;
using Hypo.Windows.App.Shell;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// The history window, shown for real and captured.
///
/// <para>These were assumed impossible for several plans. They are not: the
/// runner shows windows and renders them, so "nobody has seen the interface" was
/// a choice rather than a constraint.</para>
/// </summary>
[Collection("wpf")]
public class HistoryWindowTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-ui").FullName;
    private readonly ClipboardHistoryStore _history;
    private readonly StubClipboard _clipboard = new();

    public HistoryWindowTests() =>
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));

    public void Dispose()
    {
        _history.Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    private sealed class StubClipboard : IClipboard
    {
        public event EventHandler<ClipboardContent>? ContentChanged;

        public List<ClipboardContent> Writes { get; } = [];

        public Task<ClipboardContent?> GetAsync(CancellationToken ct = default)
        {
            _ = ContentChanged;
            return Task.FromResult<ClipboardContent?>(null);
        }

        public Task SetAsync(ClipboardContent content, CancellationToken ct = default)
        {
            Writes.Add(content);
            return Task.CompletedTask;
        }
    }

    private void Add(string text, int minute, string? from = null) => _history.Add(new HistoryEntry
    {
        Content = new ClipboardContent { ContentType = ContentType.Text, Data = Encoding.UTF8.GetBytes(text) },
        CopiedAt = DateTimeOffset.UnixEpoch.AddMinutes(minute),
        SourceDeviceName = from,
        SourceDeviceId = from is null ? null : "peer",
    });

    private HistoryViewModel Model()
    {
        var model = new HistoryViewModel(_history, _clipboard);
        model.Refresh();
        return model;
    }

    [SkippableFact]
    public void ShowsItsEntriesAndRendersThem()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Add("a link: https://example.com", 3, from: "OPPO PLP110");
        Add("some copied text from the phone", 2, from: "OPPO PLP110");
        Add("something copied on this PC", 1);

        Wpf.Run(() =>
        {
            var window = new HistoryWindow(Model());
            window.Show();

            var list = (System.Windows.Controls.ListBox)window.FindName("Rows");
            Assert.Equal(3, list.Items.Count);

            var pixels = window.Capture("history-window");

            // A window that failed to lay out renders as one flat colour, and an
            // assertion that a bitmap exists would pass anyway.
            Assert.True(Wpf.HasVisibleContent(pixels), "the window rendered blank");

            window.Close();
        });
    }

    [SkippableFact]
    public void ShowsAHintWhenThereIsNothingYet()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = new HistoryWindow(Model());
            window.Show();
            window.Settle();

            var hint = (System.Windows.Controls.TextBlock)window.FindName("Hint");
            var list = (System.Windows.Controls.ListBox)window.FindName("Rows");

            Assert.Equal(Visibility.Visible, hint.Visibility);
            Assert.Empty(list.Items);

            window.Capture("history-window-empty");
            window.Close();
        });
    }

    [SkippableFact]
    public void TypingInTheFilterNarrowsTheList()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Add("keep this one", 2);
        Add("drop the other", 1);

        Wpf.Run(() =>
        {
            var window = new HistoryWindow(Model());
            window.Show();
            window.Settle();

            var filter = (System.Windows.Controls.TextBox)window.FindName("FilterBox");
            var list = (System.Windows.Controls.ListBox)window.FindName("Rows");

            Assert.Equal(2, list.Items.Count);

            // Through the control, so the TextChanged wiring is under test rather
            // than the view model on its own.
            filter.Text = "keep";
            window.Settle();

            Assert.Single(list.Items);

            window.Capture("history-window-filtered");
            window.Close();
        });
    }

    [SkippableFact]
    public void TheSearchBoxSaysWhatItIsFor()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Add("something", 1);

        Wpf.Run(() =>
        {
            var window = new HistoryWindow(Model());
            window.Show();
            window.Settle();

            var hint = (System.Windows.Controls.TextBlock)window.FindName("FilterHint");
            var filter = (System.Windows.Controls.TextBox)window.FindName("FilterBox");

            // An unlabelled box tells the user nothing, which only looking at it
            // made obvious.
            Assert.Equal(Visibility.Visible, hint.Visibility);

            filter.Text = "typing";
            window.Settle();

            // And it has to get out of the way once there is text behind it.
            Assert.Equal(Visibility.Collapsed, hint.Visibility);

            window.Close();
        });
    }

    [SkippableFact]
    public void DoubleClickingAnEntryPutsItBackAndGetsOutOfTheWay()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Add("an entry to paste again", 1);

        Wpf.Run(() =>
        {
            var window = new HistoryWindow(Model());
            window.Show();
            window.Settle();

            var list = (System.Windows.Controls.ListBox)window.FindName("Rows");
            list.SelectedIndex = 0;

            // Through the control's own event, so the code-behind handler is
            // what is under test rather than the view model it calls.
            list.RaiseEvent(new System.Windows.Input.MouseButtonEventArgs(
                System.Windows.Input.Mouse.PrimaryDevice, 0, System.Windows.Input.MouseButton.Left)
            {
                RoutedEvent = System.Windows.Controls.Control.MouseDoubleClickEvent,
            });

            window.Settle();

            Assert.Equal(
                "an entry to paste again",
                Encoding.UTF8.GetString(Assert.Single(_clipboard.Writes).Data));

            // Hidden, not closed: the user picked something to paste, and a
            // window left over their work has to be dismissed every time.
            Assert.False(window.IsVisible);

            window.Close();
        });
    }

    [SkippableFact]
    public void DoubleClickingNothingDoesNothing()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Add("an entry", 1);

        Wpf.Run(() =>
        {
            var window = new HistoryWindow(Model());
            window.Show();
            window.Settle();

            var list = (System.Windows.Controls.ListBox)window.FindName("Rows");
            list.SelectedIndex = -1;

            list.RaiseEvent(new System.Windows.Input.MouseButtonEventArgs(
                System.Windows.Input.Mouse.PrimaryDevice, 0, System.Windows.Input.MouseButton.Left)
            {
                RoutedEvent = System.Windows.Controls.Control.MouseDoubleClickEvent,
            });

            window.Settle();

            // Double-clicking the empty area below the list must not put the
            // last thing on the clipboard, or hide the window.
            Assert.Empty(_clipboard.Writes);
            Assert.True(window.IsVisible);

            window.Close();
        });
    }

    [SkippableFact]
    public void HasAWindowThatIsActuallySized()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // A window that opens at 0x0, or far off-screen, is a bug nothing else
        // here would notice.
        Wpf.Run(() =>
        {
            var window = new HistoryWindow(Model());
            window.Show();
            window.Settle();

            Assert.True(window.ActualWidth > 300, $"width was {window.ActualWidth}");
            Assert.True(window.ActualHeight > 300, $"height was {window.ActualHeight}");
            Assert.Equal("Hypo — Clipboard History", window.Title);

            window.Close();
        });
    }
}

/// <summary>
/// WPF is single-Application-per-process and the dispatcher is shared, so these
/// must not run beside each other.
/// </summary>
[CollectionDefinition("wpf", DisableParallelization = true)]
public class WpfCollection;
