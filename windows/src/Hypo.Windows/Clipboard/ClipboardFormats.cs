using System.Runtime.Versioning;
using System.Text;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;

namespace Hypo.Windows.Clipboard;

/// <summary>
/// Maps between Windows clipboard formats and the protocol's content types.
///
/// <para><b>CF_TEXT is deliberately unused.</b> It is encoded in the active ANSI
/// code page, so anything outside it is replaced with question marks -- for this
/// project that means Chinese text arriving as <c>????</c>. Plan 3 got CJK
/// across the wire intact and it must not be lost at the last step, so text is
/// always CF_UNICODETEXT.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public static class ClipboardFormats
{
    public const uint CfText = 1;
    public const uint CfUnicodeText = 13;
    public const uint CfHdrop = 15;

    /// <summary>
    /// Classifies decoded clipboard text.
    ///
    /// <para>A link is text that parses as an absolute URI with a scheme we
    /// would actually follow. <c>Uri.IsWellFormedUriString</c> alone is too
    /// generous: <c>C:\Users</c> parses as an absolute <c>file:</c> URI, and
    /// calling a Windows path a link would mislabel a large share of everything
    /// anyone copies on Windows.</para>
    /// </summary>
    public static ContentType ClassifyText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        var trimmed = text.Trim();
        if (trimmed.Length == 0 || trimmed.Contains('\n') || trimmed.Contains('\r'))
        {
            return ContentType.Text;
        }

        return Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)
               && uri.Scheme is "http" or "https" or "ftp" or "mailto"
            ? ContentType.Link
            : ContentType.Text;
    }

    /// <summary>
    /// Decodes a CF_UNICODETEXT buffer: UTF-16LE, NUL-terminated.
    ///
    /// <para>The terminator is not always present when another application
    /// wrote a size that excludes it, so the NUL is searched for rather than
    /// assumed -- taking the whole buffer would append a stray NUL to every
    /// string, which then travels to the peer and shows up as a phantom
    /// character in its history.</para>
    /// </summary>
    public static string DecodeUnicodeText(ReadOnlySpan<byte> buffer)
    {
        var text = Encoding.Unicode.GetString(buffer);
        var terminator = text.IndexOf('\0');
        return terminator >= 0 ? text[..terminator] : text;
    }

    /// <summary>Encodes text for CF_UNICODETEXT, including the NUL terminator.</summary>
    public static byte[] EncodeUnicodeText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return Encoding.Unicode.GetBytes(text + '\0');
    }

    /// <summary>The clipboard format that carries a given content type, or null if we cannot place it.</summary>
    public static uint? FormatFor(ContentType type) => type switch
    {
        ContentType.Text or ContentType.Link => CfUnicodeText,
        ContentType.File => CfHdrop,
        _ => null,
    };

    /// <summary>Builds content from decoded text, classifying it on the way.</summary>
    public static ClipboardContent FromText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        return new ClipboardContent
        {
            ContentType = ClassifyText(text),
            Data = Encoding.UTF8.GetBytes(text),
        };
    }
}
