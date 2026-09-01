using System.IO;
using System.Text;
using System.Windows.Input;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.App;
using Hypo.Windows.App.Shell;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// Using the history without a mouse.
///
/// <para>The shortcut opens this window; if it then asks for the mouse, the
/// shortcut has saved nobody anything. Type, arrow, Enter, and Escape are the
/// whole interaction.</para>
/// </summary>
[Collection("wpf")]
public class HistoryKeyboardTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-keys").FullName;
    private readonly ClipboardHistoryStore _history;
    private readonly RecordingClipboard _clipboard = new();

    public HistoryKeyboardTests()
    {
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));

        foreach (var (text, minute) in new[] { ("first thing", 3), ("second thing", 2), ("third thing", 1) })
        {
            _history.Add(new HistoryEntry
            {
                Content = new ClipboardContent
                {
                    ContentType = ContentType.Text,
                    Data = Encoding.UTF8.GetBytes(text),
                },
                CopiedAt = DateTimeOffset.UnixEpoch.AddMinutes(minute),
            });
        }
    }

    public void Dispose()
    {
        _history.Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    private sealed class RecordingClipboard : IClipboard
    {
        public event EventHandler<ClipboardContent>? ContentChanged;

        public List<ClipboardContent> Written { get; } = [];

        public Task<ClipboardContent?> GetAsync(CancellationToken ct = default)
        {
            _ = ContentChanged;
            return Task.FromResult<ClipboardContent?>(null);
        }

        public Task SetAsync(ClipboardContent content, CancellationToken ct = default)
        {
            Written.Add(content);
            return Task.CompletedTask;
        }
    }

    private HistoryWindow Open()
    {
        var model = new HistoryViewModel(_history, _clipboard);
        model.Refresh();

        var window = new HistoryWindow(model) { HideWhenDeactivated = false };
        window.Show();
        window.Settle();
        window.ReadyToType();
        window.Settle();

        return window;
    }

    private static void Press(HistoryWindow window, Key key)
    {
        var target = Keyboard.FocusedElement ?? window;

        target.RaiseEvent(new System.Windows.Input.KeyEventArgs(
            Keyboard.PrimaryDevice,
            System.Windows.PresentationSource.FromVisual(window),
            0,
            key)
        {
            RoutedEvent = Keyboard.PreviewKeyDownEvent,
        });

        target.RaiseEvent(new System.Windows.Input.KeyEventArgs(
            Keyboard.PrimaryDevice,
            System.Windows.PresentationSource.FromVisual(window),
            0,
            key)
        {
            RoutedEvent = Keyboard.KeyDownEvent,
        });

        window.Settle();
    }

    [SkippableFact]
    public void TheSearchBoxHasTheCaretAsSoonAsItOpens()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            Assert.Same(window.FindName("FilterBox"), Keyboard.FocusedElement);

            window.Close();
        });
    }

    [SkippableFact]
    public void ArrowKeysMoveTheSelectionWhileTheCaretIsInTheSearchBox()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // Without this the arrows move the caret and the second entry cannot be
        // reached at all without the mouse.
        Wpf.Run(() =>
        {
            var window = Open();
            var rows = (System.Windows.Controls.ListBox)window.FindName("Rows");

            Press(window, Key.Down);
            Assert.Equal(0, rows.SelectedIndex);

            Press(window, Key.Down);
            Assert.Equal(1, rows.SelectedIndex);

            Press(window, Key.Up);
            Assert.Equal(0, rows.SelectedIndex);

            // The top of the list is the top of the list.
            Press(window, Key.Up);
            Assert.Equal(0, rows.SelectedIndex);

            window.Close();
        });
    }

    [SkippableFact]
    public void EnterPutsTheSelectedEntryBackAndHandsFocusOn()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();
            var handedBack = false;
            window.EntryUsed += (_, _) => handedBack = true;

            Press(window, Key.Down);
            Press(window, Key.Enter);

            Assert.Single(_clipboard.Written);
            Assert.Equal("first thing", Encoding.UTF8.GetString(_clipboard.Written[0].Data));
            Assert.True(handedBack, "focus was never handed back, so the paste would go nowhere");
            Assert.False(window.IsVisible);

            window.Close();
        });
    }

    [SkippableFact]
    public void EscapeClosesItWithoutTakingAnything()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();
            var handedBack = false;
            window.EntryUsed += (_, _) => handedBack = true;

            Press(window, Key.Escape);

            Assert.False(window.IsVisible);
            Assert.Empty(_clipboard.Written);

            // Focus still goes back: someone who opened this by mistake should
            // be typing where they were, not nowhere.
            Assert.True(handedBack);

            window.Close();
        });
    }

    [SkippableFact]
    public void EnterWithNothingSelectedDoesNothingRatherThanGuessing()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            Press(window, Key.Enter);

            Assert.Empty(_clipboard.Written);
            Assert.True(window.IsVisible);

            window.Close();
        });
    }

    [SkippableFact]
    public void TheCloseButtonLeavesWithoutTakingAnything()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // WindowStyle="None" removes the system close button, so the window
        // supplies its own. Without one, anyone who has not discovered Escape is
        // stuck with a floating rectangle.
        Wpf.Run(() =>
        {
            var window = Open();
            var handedBack = false;
            window.EntryUsed += (_, _) => handedBack = true;

            ((System.Windows.Controls.Button)window.FindName("CloseButton")).RaiseEvent(
                new System.Windows.RoutedEventArgs(
                    System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.Settle();

            Assert.False(window.IsVisible);
            Assert.Empty(_clipboard.Written);
            Assert.True(handedBack);

            window.Close();
        });
    }

    [SkippableFact]
    public void ItHasNoSystemTitleBar()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            // A list a keystroke summons should not look like an application you
            // switched to. It says what it is in its own header instead.
            Assert.Equal(System.Windows.WindowStyle.None, window.WindowStyle);
            Assert.NotNull(window.FindName("TitleBar"));

            window.Capture("history-window-popup");
            window.Close();
        });
    }

    [SkippableFact]
    public void ItStaysOnTopAndOutOfAltTab()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = Open();

            // A list summoned by a keystroke is not somewhere to switch to, and
            // one that hides behind the window you switched to is useless.
            Assert.True(window.Topmost);
            Assert.False(window.ShowInTaskbar);

            window.Close();
        });
    }
}
