using System.Globalization;
using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class AppVersionTests
{
    [Fact]
    public void TheVersionIsTheRepositorysAndNotAPlaceholder()
    {
        var version = AppVersion.Current;

        // 1.0.0 is what an assembly with no <Version> reports, and it is what
        // every Hypo assembly reported until the version file was wired in.
        Assert.NotEqual("1.0.0", version);
        Assert.Matches(@"^\d+\.\d+\.\d+$", version);

        var expected = File.ReadAllText(
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "VERSION")).Trim();

        Assert.Equal(expected, version);
    }
}

public class AppThemeTests
{
    [Fact]
    public void TheSystemSettingPicksThePalette()
    {
        Assert.Equal(ThemePalette.Dark, ThemePalette.For(dark: true));
        Assert.Equal(ThemePalette.Light, ThemePalette.For(dark: false));
    }

    [Theory]
    [InlineData(10, 19045, Backdrop.Solid)]  // Windows 10 22H2
    [InlineData(10, 22000, Backdrop.Mica)]   // Windows 11 21H2, the first build
    [InlineData(10, 26100, Backdrop.Mica)]   // Windows 11 24H2
    public void MicaOnlyWhereItExists(int major, int build, Backdrop expected)
    {
        // Asking for Mica on Windows 10 is not an error -- it silently does
        // nothing -- so the fallback has to be a decision, not an accident.
        Assert.Equal(expected, ThemePalette.BackdropFor(new Version(major, 0, build)));
    }

    [Fact]
    public void EveryColourIsAReadableHexValue()
    {
        foreach (var palette in new[] { ThemePalette.Light, ThemePalette.Dark })
        {
            foreach (var colour in Colours(palette))
            {
                Assert.Matches("^#FF[0-9A-F]{6}$", colour);
            }
        }
    }

    [Fact]
    public void DarkTextStandsOutAgainstDarkAndLightAgainstLight()
    {
        // Not a style preference: a palette that fails this is unreadable, and
        // nothing else here would catch a swapped pair of hex values.
        AssertContrast(ThemePalette.Light, minimum: 4.5);
        AssertContrast(ThemePalette.Dark, minimum: 4.5);
    }

    [Fact]
    public void TheQuietestTextIsStillLegible()
    {
        // The search hint and the caption under each entry. WCAG's 3:1 floor for
        // incidental text; below that the dark theme's small print disappears.
        foreach (var palette in new[] { ThemePalette.Light, ThemePalette.Dark })
        {
            foreach (var quiet in new[] { palette.SecondaryText, palette.TertiaryText, palette.Success })
            {
                Assert.True(
                    Contrast(quiet, palette.WindowBackground) >= 3.0,
                    $"{quiet} on {palette.WindowBackground} is {Contrast(quiet, palette.WindowBackground):F2}:1");
            }
        }
    }

    private static void AssertContrast(ThemePalette palette, double minimum)
    {
        var ratio = Contrast(palette.Text, palette.WindowBackground);
        Assert.True(ratio >= minimum, $"body text is {ratio:F2}:1, below {minimum}:1");
    }

    private static IEnumerable<string> Colours(ThemePalette palette) =>
    [
        palette.WindowBackground, palette.Text, palette.SecondaryText,
        palette.TertiaryText, palette.Success, palette.ControlBackground, palette.ControlBorder,
    ];

    private static double Contrast(string a, string b)
    {
        var (first, second) = (Luminance(a), Luminance(b));
        var (lighter, darker) = first > second ? (first, second) : (second, first);

        return (lighter + 0.05) / (darker + 0.05);
    }

    private static double Luminance(string hex)
    {
        double Channel(int offset)
        {
            var value = int.Parse(hex.Substring(offset, 2), NumberStyles.HexNumber) / 255.0;

            return value <= 0.03928 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }

        return (0.2126 * Channel(3)) + (0.7152 * Channel(5)) + (0.0722 * Channel(7));
    }
}
