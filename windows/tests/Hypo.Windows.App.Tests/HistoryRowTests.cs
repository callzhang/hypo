using System.IO;
using System.Text;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Core.Transport;
using Hypo.Windows.App;
using Hypo.Windows.App.Shell;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// The filter controls and what a row shows, in a real window.
/// </summary>
[Collection("wpf")]
public class HistoryRowTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-rows").FullName;
    private readonly ClipboardHistoryStore _history;

    public HistoryRowTests()
    {
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));

        Add(ContentType.Text, "a note to self", DateTimeOffset.Now.AddMinutes(-5));
        Add(ContentType.Link, "https://example.com/thing", DateTimeOffset.Now.AddHours(-3), TransportOrigin.Lan);
        Add(ContentType.Image, "not really a png", DateTimeOffset.Now.AddDays(-2), TransportOrigin.Cloud);
        Add(ContentType.File, "report", DateTimeOffset.Now.AddDays(-20));
    }

    public void Dispose()
    {
        _history.Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    private void Add(ContentType type, string body, DateTimeOffset at, TransportOrigin? origin = null) =>
        _history.Add(new HistoryEntry
        {
            Content = new ClipboardContent
            {
                ContentType = type,
                Data = Encoding.UTF8.GetBytes(body),
                Metadata = type is ContentType.File
                    ? new Dictionary<string, string> { ["file_name"] = "report.pdf" }
                    : null,
            },
            CopiedAt = at,
            SourceDeviceName = origin is null ? null : "OPPO PLP110",
            SourceDeviceId = origin is null ? null : "bbe296d6-0785-43d2-91b6-b135b72f4c41",
            Origin = origin,
        });

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

    private HistoryWindow Open()
    {
        var model = new HistoryViewModel(_history, new NullClipboard());
        model.Refresh();

        var window = new HistoryWindow(model) { HideWhenDeactivated = false };
        window.Show();
        window.Settle();

        return window;
    }

    [SkippableFact]
    public void BothFiltersAreOfferedAndStartAtEverything()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            var types = (System.Windows.Controls.ComboBox)window.FindName("TypeFilterBox");
            var dates = (System.Windows.Controls.ComboBox)window.FindName("DateFilterBox");

            Assert.Equal(5, types.Items.Count);
            Assert.Equal(3, dates.Items.Count);
            Assert.Equal(0, types.SelectedIndex);
            Assert.Equal(0, dates.SelectedIndex);

            Assert.Equal(4, ((System.Windows.Controls.ListBox)window.FindName("Rows")).Items.Count);

            window.Capture("history-window-filters");
            window.Close();
        });
    }

    [SkippableFact]
    public void ChoosingATypeNarrowsTheList()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();
            var types = (System.Windows.Controls.ComboBox)window.FindName("TypeFilterBox");
            var rows = (System.Windows.Controls.ListBox)window.FindName("Rows");

            types.SelectedIndex = 3; // Images
            window.Settle();

            var row = Assert.IsType<HistoryRow>(Assert.Single(rows.Items));
            Assert.Equal(ContentType.Image, row.ContentType);

            window.Close();
        });
    }

    [SkippableFact]
    public void ChoosingADateNarrowsTheList()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();
            var dates = (System.Windows.Controls.ComboBox)window.FindName("DateFilterBox");
            var rows = (System.Windows.Controls.ListBox)window.FindName("Rows");

            dates.SelectedIndex = 1; // Today
            window.Settle();

            Assert.Equal(2, rows.Items.Count);

            window.Close();
        });
    }

    [SkippableFact]
    public void AnEmptyResultSaysWhichEmptinessThisIs()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // "Copy something" is wrong advice for a list emptied by a filter, and
        // sends the reader off to do something that will not help.
        Wpf.Run(() =>
        {
            var window = Open();
            var hint = (System.Windows.Controls.TextBlock)window.FindName("Hint");

            ((System.Windows.Controls.TextBox)window.FindName("FilterBox")).Text = "nothing matches this";
            window.Settle();

            Assert.Equal(System.Windows.Visibility.Visible, hint.Visibility);
            Assert.Contains("Try a different filter", hint.Text);

            window.Capture("history-window-nothing-matches");
            window.Close();
        });
    }

    [SkippableFact]
    public void PinningFromTheContextMenuMovesTheRowAndFlipsTheLabel()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();
            var rows = (System.Windows.Controls.ListBox)window.FindName("Rows");
            var pin = (System.Windows.Controls.MenuItem)window.FindName("PinItem");

            var oldest = (HistoryRow)rows.Items[^1]!;
            rows.SelectedItem = oldest;
            window.Settle();

            Assert.Equal("Pin to the top", pin.Header);

            // MenuItem.ClickEvent, not ButtonBase.ClickEvent: they are different
            // routed events, and raising the wrong one runs no handler at all
            // while looking exactly like a test that passed.
            pin.RaiseEvent(new System.Windows.RoutedEventArgs(
                System.Windows.Controls.MenuItem.ClickEvent));
            window.Settle();

            var top = Assert.IsType<HistoryRow>(rows.Items[0]);
            Assert.True(top.Pinned);
            Assert.Equal(oldest.Content.Hash, top.Content.Hash);

            window.Capture("history-window-pinned");
            window.Close();
        });
    }

    [SkippableFact]
    public void TheListVirtualisesRatherThanBuildingEveryRow()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        for (var i = 0; i < 200; i++)
        {
            Add(ContentType.Text, $"entry number {i}", DateTimeOffset.Now.AddSeconds(-i));
        }

        Wpf.Run(() =>
        {
            var window = Open();
            var rows = (System.Windows.Controls.ListBox)window.FindName("Rows");

            Assert.True(rows.Items.Count > 150, $"only {rows.Items.Count} rows loaded");

            // Two hundred rows each with a glyph and three lines of text is
            // enough that building them all up front shows as a pause.
            var realised = Enumerable.Range(0, rows.Items.Count)
                .Count(i => rows.ItemContainerGenerator.ContainerFromIndex(i) is not null);

            Assert.True(
                realised < rows.Items.Count,
                $"every one of the {rows.Items.Count} rows was built, so the list is not virtualising");

            window.Close();
        });
    }
}
