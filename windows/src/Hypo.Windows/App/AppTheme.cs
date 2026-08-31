namespace Hypo.Windows.App;

/// <summary>What is behind the window.</summary>
public enum Backdrop
{
    /// <summary>Windows 11's blurred, wallpaper-tinted material.</summary>
    Mica,

    /// <summary>A flat colour. Windows 10 has no Mica and never will.</summary>
    Solid,
}

/// <summary>
/// The colours, and which of them to use.
///
/// <para>Kept out of XAML and away from the window classes so the choice is
/// testable on any machine: which palette follows from the system setting, and
/// which backdrop follows from the Windows version, are decisions, and the
/// Windows 10 fallback in particular is one the design asks to be written down
/// rather than left to whatever a missing API does.</para>
/// </summary>
public sealed record ThemePalette
{
    /// <summary>Windows 11's first build. Mica does not exist below it.</summary>
    private const int FirstWindows11Build = 22000;

    public required string WindowBackground { get; init; }

    public required string Text { get; init; }

    /// <summary>Captions and the line under each entry.</summary>
    public required string SecondaryText { get; init; }

    /// <summary>The search hint and the empty-list message: present, not shouting.</summary>
    public required string TertiaryText { get; init; }

    /// <summary>"Already paired", and nothing else.</summary>
    public required string Success { get; init; }

    public required string ControlBackground { get; init; }

    public required string ControlBorder { get; init; }

    /// <summary>Whether this is the dark one, which the window frame also needs to know.</summary>
    public required bool IsDark { get; init; }

    public static ThemePalette Light { get; } = new()
    {
        IsDark = false,
        WindowBackground = "#FFF9F9F9",
        Text = "#FF1A1A1A",
        SecondaryText = "#FF6B6B6B",
        TertiaryText = "#FF8A8A8A",
        Success = "#FF3A7D44",
        ControlBackground = "#FFFFFFFF",
        ControlBorder = "#FFD0D0D0",
    };

    public static ThemePalette Dark { get; } = new()
    {
        IsDark = true,
        WindowBackground = "#FF202020",
        Text = "#FFF2F2F2",
        // Lightened rather than reused: #FF6B6B6B on #FF202020 is under 3:1 and
        // the caption line under every entry is the smallest text in the window.
        SecondaryText = "#FFB0B0B0",
        TertiaryText = "#FF8C8C8C",
        // The light green goes muddy on a dark background.
        Success = "#FF6FCF7F",
        ControlBackground = "#FF2B2B2B",
        ControlBorder = "#FF3F3F3F",
    };

    public static ThemePalette For(bool dark) => dark ? Dark : Light;

    /// <summary>
    /// Mica on Windows 11, a solid colour anywhere else.
    ///
    /// <para>Asking for Mica below Windows 11 is not an error -- the call simply
    /// does nothing -- which is exactly why the fallback is decided here instead
    /// of being whatever the window happens to look like afterwards.</para>
    /// </summary>
    public static Backdrop BackdropFor(Version osVersion)
    {
        ArgumentNullException.ThrowIfNull(osVersion);

        return osVersion.Major >= 10 && osVersion.Build >= FirstWindows11Build
            ? Backdrop.Mica
            : Backdrop.Solid;
    }
}
