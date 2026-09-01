using System.Reflection;

namespace Hypo.Windows.App;

/// <summary>
/// What this build calls itself.
///
/// <para>Read from the assembly rather than written down twice: the version
/// comes from the repository's <c>VERSION</c> file through MSBuild, and a
/// constant here would be the copy that goes stale.</para>
/// </summary>
public static class AppVersion
{
    /// <summary>
    /// The version, without the commit that MSBuild appends in a source-linked
    /// build -- "1.2.0", never "1.2.0+b9a4d6a".
    /// </summary>
    public static string Current { get; } = Read();

    private static string Read()
    {
        var informational = typeof(AppVersion).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;

        if (!string.IsNullOrWhiteSpace(informational))
        {
            var plus = informational.IndexOf('+');

            return plus < 0 ? informational : informational[..plus];
        }

        // A version-less assembly reports 1.0.0, which would be a lie in a menu.
        return typeof(AppVersion).Assembly.GetName().Version?.ToString(3) ?? "unknown";
    }
}
