using System.Buffers;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace Hypo.Windows.Clipboard;

/// <summary>
/// The <c>CF_HDROP</c> payload: a <c>DROPFILES</c> header followed by a
/// double-NUL-terminated list of paths.
///
/// <para>Encoding and decoding live here, away from the clipboard calls, because
/// the layout is the part that is easy to get subtly wrong and the only part
/// that can be tested without a clipboard at all.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public static class ClipboardFiles
{
    /// <summary>Matches the Win32 DROPFILES struct: 20 bytes, then the path list.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct DropFiles
    {
        public uint Size;
        public int PointX;
        public int PointY;
        public int NonClientArea;
        public int Wide;
    }

    public static readonly int HeaderSize = Marshal.SizeOf<DropFiles>();

    /// <summary>
    /// Builds a CF_HDROP payload for <paramref name="paths"/>.
    ///
    /// <para>Always wide. Writing the ANSI form would mangle any path outside the
    /// active code page, and a Chinese filename is exactly the case this project
    /// keeps having to defend.</para>
    /// </summary>
    public static byte[] Encode(IReadOnlyList<string> paths)
    {
        ArgumentNullException.ThrowIfNull(paths);

        if (paths.Count == 0)
        {
            throw new ArgumentException("A CF_HDROP with no paths has no meaning.", nameof(paths));
        }

        // Each path NUL-terminated, then one more NUL to end the list.
        var list = string.Join('\0', paths) + "\0\0";
        var listBytes = Encoding.Unicode.GetBytes(list);

        var buffer = new byte[HeaderSize + listBytes.Length];

        var header = new DropFiles
        {
            Size = (uint)HeaderSize,
            Wide = 1,
        };

        MemoryMarshal.Write(buffer, in header);
        listBytes.CopyTo(buffer.AsSpan(HeaderSize));

        return buffer;
    }

    /// <summary>
    /// Reads the paths out of a CF_HDROP payload, or an empty list when it is
    /// malformed. Another application's buffer is not something to trust.
    /// </summary>
    public static IReadOnlyList<string> Decode(ReadOnlySpan<byte> buffer)
    {
        if (buffer.Length < HeaderSize)
        {
            return [];
        }

        var header = MemoryMarshal.Read<DropFiles>(buffer);
        if (header.Size < HeaderSize || header.Size > buffer.Length)
        {
            return [];
        }

        var listBytes = buffer[(int)header.Size..];

        var text = header.Wide != 0
            ? Encoding.Unicode.GetString(listBytes)
            // ANSI is legal and rare. Reading it with the active code page is the
            // best available answer; producing it is not.
            : Encoding.Default.GetString(listBytes);

        return text.Split('\0', StringSplitOptions.RemoveEmptyEntries);
    }

    /// <summary>
    /// A filename safe to create on Windows from a peer-supplied one.
    ///
    /// <para>The name arrives from another device and lands on this filesystem,
    /// so it is a path injection unless it is reduced to a leaf and stripped of
    /// characters Windows forbids. <c>..\..\autorun.inf</c> must become a file
    /// name, not a traversal.</para>
    ///
    /// <para>The rules are written out rather than taken from
    /// <c>Path.GetFileName</c> and <c>Path.GetInvalidFileNameChars</c>, which
    /// answer for the host: on Unix a backslash is an ordinary character and
    /// <c>:</c> is legal, so those APIs under-sanitise everywhere except the one
    /// platform this runs on. Sanitising untrusted input must not depend on who
    /// is asking.</para>
    /// </summary>
    public static string SafeFileName(string? proposed, string fallback = "clipboard-file")
    {
        var trimmed = proposed?.Trim() ?? string.Empty;

        // Both separators, always: a name built on Unix and applied on Windows
        // would otherwise keep its backslashes and become a path. A colon is
        // *not* a separator here -- inside a filename it opens an alternate data
        // stream, so taking what follows it would keep the stream and discard the
        // file. It is replaced below instead.
        var leaf = trimmed[(trimmed.LastIndexOfAny(['/', '\\']) + 1)..];

        if (leaf.Length == 0 || leaf is "." or ".." || leaf.All(c => c == '.'))
        {
            return fallback;
        }

        var cleaned = new string(leaf.Select(c => Invalid.Contains(c) || c < ' ' ? '_' : c).ToArray())
            // Windows silently drops these from the end, so a name that is only
            // dots and spaces would resolve to the directory itself.
            .TrimEnd('.', ' ');

        if (cleaned.Length == 0 || cleaned.All(c => c == '_'))
        {
            return fallback;
        }

        // CON, NUL, COM1 and friends are device names at any extension: creating
        // one does not fail, it opens a device.
        var stem = cleaned.Split('.')[0];
        return Reserved.Contains(stem) ? $"_{cleaned}" : cleaned;
    }

    private static readonly SearchValues<char> Invalid =
        SearchValues.Create("<>:\"/\\|?*");

    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };
}
