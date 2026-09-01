using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Media;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.App;
using Hypo.Windows.App.Shell;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// Light and dark, rendered.
///
/// <para>A palette that is merely present in a dictionary proves nothing: what
/// matters is whether the window picked it up, and whether the text is still
/// readable against it. Both are checked from the pixels.</para>
/// </summary>
[Collection("wpf")]
public class ThemeTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-theme").FullName;
    private readonly ClipboardHistoryStore _history;

    public ThemeTests()
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
    [InlineData(true, "dark")]
    [InlineData(false, "light")]
    public void TheHistoryWindowTakesTheThemeItIsGiven(bool dark, string label)
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            var palette = ThemePalette.For(dark);
            ThemeHost.Apply(System.Windows.Application.Current, palette);

            try
            {
                var model = new HistoryViewModel(_history, new NullClipboard());
                model.Refresh();

                var window = new HistoryWindow(model);
                window.Show();
                window.Settle();

                var pixels = window.Capture($"history-window-{label}", 96);

                Assert.True(Wpf.HasVisibleContent(pixels), $"blank in the {label} theme");

                // The window's own background, not a brush sitting in a
                // dictionary: a Style that stopped applying would leave the
                // dictionary correct and the window white.
                var background = Assert.IsType<SolidColorBrush>(window.Background);
                Assert.Equal(palette.WindowBackground, background.Color.ToString());
            }
            finally
            {
                ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.Light);
            }
        });
    }

    [SkippableFact]
    public void NoControlKeepsItsLightChromeInTheDarkTheme()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // Twice now a control WPF styles itself has been left out of the theme
        // and turned up as a pale slab with white text on it -- first Button,
        // then ComboBox -- and both times a person looking at a screenshot found
        // it rather than a test. This asks the pixels.
        Wpf.Run(() =>
        {
            ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.Dark);

            try
            {
                var model = new HistoryViewModel(_history, new NullClipboard());
                model.Refresh();

                var window = new HistoryWindow(model) { HideWhenDeactivated = false };
                window.Show();
                window.Settle();

                var content = (System.Windows.FrameworkElement)window.Content;
                var pixels = window.Capture(name: null);

                Assert.False(
                    Wpf.HasLightChrome(pixels, (int)window.ActualWidth, (int)content.ActualHeight),
                    "something in the dark theme is still wearing its light chrome");

                window.Close();
            }
            finally
            {
                ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.Light);
            }
        });
    }

    [SkippableFact]
    public void ThePairingWindowKeepsNoLightChromeEither()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.Dark);

            try
            {
                var store = new Hypo.Core.Abstractions.InMemorySecretStore();
                var window = new PairingWindow(new PairingViewModel(
                    store,
                    new Hypo.Core.Pairing.LanPairingCoordinator(store),
                    "11111111-2222-3333-4444-555555555555",
                    "Test PC"));

                window.Show();
                window.Settle();

                var content = (System.Windows.FrameworkElement)window.Content;
                var pixels = window.Capture(name: null);

                Assert.False(
                    Wpf.HasLightChrome(pixels, (int)window.ActualWidth, (int)content.ActualHeight),
                    "something in the dark theme is still wearing its light chrome");

                window.Close();
            }
            finally
            {
                ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.Light);
            }
        });
    }

    [SkippableFact]
    public void SwitchingThemeRepaintsAWindowThatIsAlreadyOpen()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // Changing the system theme with Hypo already running is exactly when a
        // window that only reads the setting once would be noticed.
        Wpf.Run(() =>
        {
            var model = new HistoryViewModel(_history, new NullClipboard());
            model.Refresh();

            var window = new HistoryWindow(model);
            window.Show();
            window.Settle();

            try
            {
                ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.Dark);
                window.Settle();

                Assert.Equal(
                    ThemePalette.Dark.WindowBackground,
                    ((SolidColorBrush)window.Background).Color.ToString());

                ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.Light);
                window.Settle();

                Assert.Equal(
                    ThemePalette.Light.WindowBackground,
                    ((SolidColorBrush)window.Background).Color.ToString());
            }
            finally
            {
                window.Close();
                ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.Light);
            }
        });
    }

    [SkippableTheory]
    [InlineData(true, "dark")]
    [InlineData(false, "light")]
    public void ThePairingWindowTakesTheThemeToo(bool dark, string label)
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        Wpf.Run(() =>
        {
            ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.For(dark));

            try
            {
                var store = new Hypo.Core.Abstractions.InMemorySecretStore();
                var window = new PairingWindow(new PairingViewModel(
                    store,
                    new Hypo.Core.Pairing.LanPairingCoordinator(store),
                    "11111111-2222-3333-4444-555555555555",
                    "Test PC"));
                window.Show();
                window.Settle();

                Assert.True(
                    Wpf.HasVisibleContent(window.Capture($"pairing-window-{label}", 96)),
                    $"blank in the {label} theme");

                window.Close();
            }
            finally
            {
                ThemeHost.Apply(System.Windows.Application.Current, ThemePalette.Light);
            }
        });
    }

    [SkippableFact]
    public void TheSystemSettingIsReadable()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "Windows-only.");

        // Whichever way this machine is set, reading it must not throw -- the
        // value is absent entirely on a fresh profile.
        _ = ThemeHost.SystemPrefersDark();
    }
}
