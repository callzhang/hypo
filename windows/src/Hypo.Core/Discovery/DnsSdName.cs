using System.Text;

namespace Hypo.Core.Discovery;

/// <summary>
/// DNS-SD instance names arrive escaped per RFC 1035: a backslash followed by
/// three decimal digits is a byte value, and a backslash before any other
/// character escapes it literally. Measured examples from live peers include
/// "derek\8217s\032MacBook\032Air\032(2)".
/// </summary>
/// <remarks>
/// One case stays undecidable and is deliberately left alone: "\2339" could be
/// 233 followed by a literal "9", or 2339. Both readings obey the encoder's
/// padding rule, so no parser can tell them apart. It needs a non-ASCII
/// character immediately followed by a digit, which is far rarer than the
/// space-then-digit case the width rule below fixes.
/// </remarks>
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
            while (digits < 5 && i + 1 + digits < value.Length && char.IsAsciiDigit(value[i + 1 + digits]))
            {
                digits++;
            }

            if (digits >= 3)
            {
                // The encoder zero-pads to a minimum of three digits and never
                // pads wider than the value needs, so a leading zero proves the
                // escape is exactly three digits and any further digits are
                // literal text. Without this, "Air 9" arrives as "Air\0329" and
                // is misread as one code point.
                var width = value[i + 1] == '0' ? 3 : digits;
                var parsed = int.Parse(value.AsSpan(i + 1, width));

                // A wider reading that will not fit in a char cannot be what the
                // encoder meant, so fall back to three digits.
                if (parsed > char.MaxValue && width > 3)
                {
                    width = 3;
                    parsed = int.Parse(value.AsSpan(i + 1, width));
                }

                sb.Append((char)parsed);
                i += width;
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
