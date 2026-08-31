using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Hypo.Windows.App;
using Microsoft.Win32;

namespace Hypo.Windows.App.Shell;

/// <summary>
/// Follows the system light/dark setting.
///
/// <para>Which colours and which backdrop are <see cref="ThemePalette"/>'s
/// decisions, and tested there. This is the part that cannot be: reading the
/// setting, putting brushes in the resource dictionary, and telling the window
/// frame what it is sitting on.</para>
/// </summary>
public static class ThemeHost
{
    private const string PersonalizeKey =
        @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaSystemBackdropType = 38;
    private const int BackdropMainWindow = 2; // DWMSBT_MAINWINDOW -- Mica.
    private const int BackdropNone = 1;

    private static readonly List<WeakReference<Window>> Windows = [];

    /// <summary>
    /// Whether Windows is set to dark.
    ///
    /// <para><c>AppsUseLightTheme</c> rather than <c>SystemUsesLightTheme</c>:
    /// the second is the taskbar and the Start menu, and a user can set them
    /// apart. Missing means light -- that is what Windows does with it.</para>
    /// </summary>
    public static bool SystemPrefersDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);

            return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// Applies the current setting and keeps following it.
    ///
    /// <para>Changing the theme while the application is open is exactly when
    /// someone would notice a window that did not change with it.</para>
    /// </summary>
    public static void Follow(System.Windows.Application application)
    {
        ArgumentNullException.ThrowIfNull(application);

        Apply(application, ThemePalette.For(SystemPrefersDark()));

        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category is not UserPreferenceCategory.General)
            {
                return;
            }

            application.Dispatcher.BeginInvoke(() =>
                Apply(application, ThemePalette.For(SystemPrefersDark())));
        };
    }

    /// <summary>Puts the palette in the resource dictionary and repaints the frames.</summary>
    public static void Apply(System.Windows.Application application, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(application);
        ArgumentNullException.ThrowIfNull(palette);

        Set(application, "WindowBackgroundBrush", palette.WindowBackground);
        Set(application, "TextBrush", palette.Text);
        Set(application, "SecondaryTextBrush", palette.SecondaryText);
        Set(application, "TertiaryTextBrush", palette.TertiaryText);
        Set(application, "SuccessBrush", palette.Success);
        Set(application, "ControlBackgroundBrush", palette.ControlBackground);
        Set(application, "ControlBorderBrush", palette.ControlBorder);

        application.Resources["IsDarkTheme"] = palette.IsDark;

        lock (Windows)
        {
            Windows.RemoveAll(reference => !reference.TryGetTarget(out _));

            foreach (var reference in Windows)
            {
                if (reference.TryGetTarget(out var window))
                {
                    Dress(window, palette);
                }
            }
        }
    }

    /// <summary>
    /// Applies the frame to one window, and remembers it for the next change.
    ///
    /// <para>Called from the window itself once it has a handle: the title bar
    /// and the backdrop are set through <c>DwmSetWindowAttribute</c>, which
    /// needs one.</para>
    /// </summary>
    public static void Register(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);

        lock (Windows)
        {
            Windows.Add(new WeakReference<Window>(window));
        }

        Dress(window, ThemePalette.For(SystemPrefersDark()));
    }

    private static void Dress(Window window, ThemePalette palette)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == 0)
        {
            return;
        }

        var dark = palette.IsDark ? 1 : 0;
        DwmSetWindowAttribute(handle, DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));

        // Mica on Windows 11 and a solid colour below it, decided rather than
        // discovered: asking for Mica on Windows 10 is not an error, it simply
        // does nothing, and the window would keep whatever it had.
        var backdrop = ThemePalette.BackdropFor(Environment.OSVersion.Version) is Backdrop.Mica
            ? BackdropMainWindow
            : BackdropNone;

        DwmSetWindowAttribute(handle, DwmwaSystemBackdropType, ref backdrop, sizeof(int));
    }

    private static void Set(System.Windows.Application application, string key, string colour) =>
        application.Resources[key] = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(colour)!);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
}
