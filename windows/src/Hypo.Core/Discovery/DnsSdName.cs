using System.Text;

namespace Hypo.Core.Discovery;

/// <summary>
/// DNS-SD instance names arrive escaped per RFC 1035: a backslash followed by
/// three decimal digits is a byte value, and a backslash before any other
/// character escapes it literally. Measured examples from live peers include
/// "derek\8217s\032MacBook\032Air\032(2)".
/// </summary>
public static class DnsSdName
{
    public static string Unescape(string value)
    {
        ArgumentNullException.ThrowIfNull(value);

        var sb = new StringBuilder(value.Length);
        for (var i = 0; i < value.Length; i++)
        {
            if (value[i] != '\\')
            {
                sb.Append(value[i]);
                continue;
            }

            if (i + 1 >= value.Length)
            {
                sb.Append('\\');
                break;
            }

            var digits = 0;
            while (digits < 4 && i + 1 + digits < value.Length && char.IsAsciiDigit(value[i + 1 + digits]))
            {
                digits++;
            }

            if (digits >= 3)
            {
                sb.Append((char)int.Parse(value.AsSpan(i + 1, digits)));
                i += digits;
            }
            else
            {
                sb.Append(value[i + 1]);
                i++;
            }
        }

        return sb.ToString();
    }

    /// <summary>Unescaped instance label with the service type suffix removed.</summary>
    public static string InstanceLabel(string fullName, string serviceType)
    {
        ArgumentNullException.ThrowIfNull(fullName);
        ArgumentNullException.ThrowIfNull(serviceType);

        var suffix = "." + serviceType.TrimStart('.');
        var label = fullName.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
            ? fullName[..^suffix.Length]
            : fullName;

        return Unescape(label);
    }
}
