using System.Runtime.Versioning;
using Microsoft.Win32;

namespace Hypo.Windows.App;

/// <summary>
/// Whether Hypo starts with Windows.
///
/// <para>A clipboard tool that has to be launched by hand is one people stop
/// using: the moment it is wanted is the moment after copying something, which
/// is too late to go and start it.</para>
///
/// <para>The per-user Run key, never the machine-wide one. Hypo's state, its
/// pairings and its history are per-user, and an entry under HKLM would start it
/// for people who never installed it. It also needs no administrator.</para>
/// </summary>
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    /// <summary>The value name. Stable, so turning it on twice leaves one entry.</summary>
    public const string Name = "Hypo";

    /// <summary>
    /// How the entry is written for a given executable.
    ///
    /// <para>Quoted, always. Windows splits an unquoted Run entry at spaces, and
    /// the obvious home for an unpacked zip is under
    /// <c>%LOCALAPPDATA%\Programs\Hypo</c> — where a user name with a space in it
    /// is enough to make the entry point at nothing.</para>
    /// </summary>
    public static string CommandFor(string executablePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);

        return $"\"{executablePath.Trim('"')}\"";
    }

    [SupportedOSPlatform("windows")]
    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);

            return key?.GetValue(Name) is string value && !string.IsNullOrWhiteSpace(value);
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// Turns it on or off, and says whether it worked.
    ///
    /// <para>Group policy can lock this key on a managed machine. Failing
    /// silently would leave a switch that says one thing and does another, so
    /// the caller gets the reason to show.</para>
    /// </summary>
    [SupportedOSPlatform("windows")]
    public static string? Set(bool enabled, string executablePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);

        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true)
                ?? throw new InvalidOperationException("The startup key could not be opened.");

            if (enabled)
            {
                key.SetValue(Name, CommandFor(executablePath), RegistryValueKind.String);
            }
            else
            {
                key.DeleteValue(Name, throwOnMissingValue: false);
            }

            return null;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException
            or UnauthorizedAccessException or InvalidOperationException or IOException)
        {
            return $"Windows would not let Hypo change this: {ex.Message}";
        }
    }
}
