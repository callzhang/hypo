namespace Hypo.Core.Protocol;

/// <summary>
/// Base64 decoding that tolerates missing padding. The Android client encodes
/// with Base64.withoutPadding(), which Convert.FromBase64String rejects.
/// </summary>
public static class Base64Compat
{
    public static byte[] Decode(string value)
    {
        ArgumentNullException.ThrowIfNull(value);

        var remainder = value.Length % 4;
        var padded = remainder == 0 ? value : value + new string('=', 4 - remainder);
        return Convert.FromBase64String(padded);
    }

    public static string Encode(ReadOnlySpan<byte> value) => Convert.ToBase64String(value);
}
