using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Media;
using Hypo.Core.Abstractions;
using Hypo.Core.History;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.App;
using Hypo.Windows.App.Shell;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// Whether the controls are actually drawn where they say they are.
///
/// <para>Layout is not the question. A control can report a sensible position
/// and size and still never reach a pixel, and every click-it-and-assert test
/// passes either way -- clicking something invisible works perfectly well in
/// code. So this reads the bitmap.</para>
/// </summary>
[Collection("wpf")]
public class FitsOnScreenTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-fits").FullName;
    private readonly ClipboardHistoryStore _history;

    public FitsOnScreenTests()
    {
        _history = new ClipboardHistoryStore(Path.Combine(_dir, "history.db"));
        _history.Add(new HistoryEntry
        {
            Content = new ClipboardContent
            {
                ContentType = ContentType.Text,
                Data = Encoding.UTF8.GetBytes("Something copied on the phone"),
            },
            CopiedAt = DateTimeOffset.UnixEpoch,
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
    [InlineData("PairButton")]
    [InlineData("CodeBox")]
    [InlineData("UseCodeButton")]
    [InlineData("ShowCodeButton")]
    public void EveryPairingControlIsInsideThePairingWindow(string name)
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var window = new PairingWindow(CodeCapableModel());

            window.Show();
            window.Settle();

            AssertInside(window, name);

            window.Close();
        });
    }

    [SkippableFact]
    public void TheCodeRowSurvivesAMessageAppearingAboveIt()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // The message row is the one thing above the code row that grows: it is
        // empty until something goes wrong, and "Choose a device first." is the
        // most common thing to see in this window.
        Wpf.Run(() =>
        {
            var window = new PairingWindow(CodeCapableModel());

            window.Show();
            window.Settle();

            // Pairing with nothing selected is what puts a message there.
            ((System.Windows.Controls.Button)window.FindName("PairButton")).RaiseEvent(
                new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            window.Settle();

            var message = (System.Windows.Controls.TextBlock)window.FindName("Message");
            Assert.False(string.IsNullOrEmpty(message.Text), "no message appeared, so this proves nothing");

            foreach (var name in new[] { "CodeBox", "UseCodeButton", "ShowCodeButton" })
            {
                AssertInside(window, name);
            }

            // Captured from the test that measured it, so the screenshot and the
            // assertion are talking about the same window.
            window.Capture("pairing-window-with-message");
            window.Close();
        });
    }

    [SkippableTheory]
    [InlineData("FilterBox")]
    [InlineData("Rows")]
    public void EveryHistoryControlIsInsideTheHistoryWindow(string name)
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var model = new HistoryViewModel(_history, new NullClipboard());
            model.Refresh();

            var window = new HistoryWindow(model);
            window.Show();
            window.Settle();

            AssertInside(window, name);

            window.Close();
        });
    }

    /// <summary>
    /// Asserts the control was actually painted, by looking at the pixels where
    /// it says it is.
    ///
    /// <para>Measuring the layout was not enough: WPF reported the pairing
    /// window's code row as comfortably inside its Grid while the screenshot
    /// showed the window ending above it. The bitmap is the thing a user
    /// sees, so the bitmap is what this asks.</para>
    /// </summary>
    /// <summary>
    /// A model that can pair by code, which is what makes the bottom row of the
    /// pairing window visible at all.
    ///
    /// <para>Without the remote coordinator the window hides that row on
    /// purpose, and a test that did not know it spent three rounds proving the
    /// controls were not drawn.</para>
    /// </summary>
    private static PairingViewModel CodeCapableModel()
    {
        var store = new InMemorySecretStore();

        return new PairingViewModel(
            store,
            new LanPairingCoordinator(store),
            "11111111-2222-3333-4444-555555555555",
            "Test PC",
            sync: null,
            remote: new RemotePairingCoordinator(
                new RelayPairingClient(new System.Net.Http.HttpClient()), store));
    }

    private static void AssertInside(Window window, string name)
    {
        var element = (FrameworkElement)window.FindName(name);

        Assert.Equal(Visibility.Visible, element.Visibility);
        Assert.True(element.ActualHeight > 0, $"{name} has no height, so it was never laid out");

        var top = (int)element.TransformToAncestor(window).Transform(default).Y;
        var bottom = (int)(top + element.ActualHeight);

        var width = (int)window.ActualWidth;
        var height = (int)window.ActualHeight;
        var pixels = window.Capture($"fits-{name}");

        Assert.True(bottom <= height, $"{name} ends {bottom - height}px past the bottom of the window");

        var colours = new HashSet<uint>();
        for (var y = Math.Max(top, 0); y < Math.Min(bottom, height); y++)
        {
            for (var x = 0; x < width; x++)
            {
                var i = ((y * width) + x) * 4;
                colours.Add(BitConverter.ToUInt32(pixels, i));
            }
        }

        // One colour across the control's whole band means nothing was drawn
        // there -- the row fell off the window, or the window ended above it.
        Assert.True(colours.Count > 1, $"{name} occupies rows {top}-{bottom}, and nothing was painted there");
    }
}
