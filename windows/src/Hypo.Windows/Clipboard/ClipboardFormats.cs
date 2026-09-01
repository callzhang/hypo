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
    public const uint CfDib = 8;

    /// <summary>
    /// The registered "PNG" format, resolved once.
    ///
    /// <para>Images travel as PNG in the protocol, and Windows has no built-in
    /// PNG format -- CF_DIB is a raw bitmap with no compression and no alpha in
    /// its classic form. Every browser and image editor publishes and accepts the
    /// registered "PNG" name, so carrying the protocol's bytes through unchanged
    /// is both simpler and lossless. Converting to CF_DIB would mean decoding and
    /// re-encoding an image to hand back something worse.</para>
    /// </summary>
    public static uint PngFormat { get; } = NativeMethods.RegisterClipboardFormat("PNG");

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
        ContentType.Image => PngFormat,
        ContentType.File => CfHdrop,
        _ => null,
    };

    /// <summary>
    /// True when the bytes begin with the PNG signature.
    ///
    /// <para>Checked before publishing an image: another client sending JPEG or a
    /// truncated file would otherwise be advertised on the clipboard as PNG, and
    /// whatever pasted it would fail in a way that looks like our bug.</para>
    /// </summary>
    public static bool LooksLikePng(ReadOnlySpan<byte> data) =>
        data.Length >= 8
        && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47
        && data[4] == 0x0D && data[5] == 0x0A && data[6] == 0x1A && data[7] == 0x0A;

    /// <summary>
    /// True when the bytes begin with a JPEG SOI marker.
    ///
    /// <para>Peers send JPEG routinely: a Mac re-encodes anything large before
    /// sending it, so refusing JPEG means the bigger the picture, the more certain
    /// it is never to arrive.</para>
    /// </summary>
    public static bool LooksLikeJpeg(ReadOnlySpan<byte> data) =>
        data.Length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF;

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
