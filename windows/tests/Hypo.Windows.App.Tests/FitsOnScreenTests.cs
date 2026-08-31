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
/// Whether the controls are inside the window.
///
/// <para>Found by looking at a screenshot: the pairing window's six-digit code
/// box and its two buttons were below the bottom edge, in every capture, light
/// and dark. Every test still passed -- clicking a control that is off-screen
/// works perfectly well in code, which is exactly why this needed measuring
/// rather than exercising.</para>
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
            var store = new InMemorySecretStore();
            var window = new PairingWindow(new PairingViewModel(
                store,
                new LanPairingCoordinator(store),
                "11111111-2222-3333-4444-555555555555",
                "Test PC"));

            window.Show();
            window.Settle();

            AssertInside(window, name);

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

    private static void AssertInside(Window window, string name)
    {
        var element = (FrameworkElement)window.FindName(name);
        var content = (FrameworkElement)window.Content;

        var bottom = element
            .TransformToAncestor(content)
            .Transform(new System.Windows.Point(0, element.ActualHeight)).Y;

        Assert.True(
            bottom <= content.ActualHeight,
            $"{name} ends {bottom - content.ActualHeight:F0}px below the window's {content.ActualHeight:F0}px of room");
    }
}
