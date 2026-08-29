namespace Hypo.Core.Sync;

/// <summary>
/// The machine's clipboard.
///
/// <para><b>A write must not be re-published as a change.</b> Applying a peer's
/// item sets the clipboard, which raises the operating system's
/// clipboard-changed notification, which a naive implementation forwards as
/// <see cref="ContentChanged"/>. The coordinator then sends it back to the peer,
/// whose clipboard changes, which it sends back. That is an unbounded loop
/// between two devices and it is the single most likely way to build one here,
/// so suppressing the echo is the implementation's responsibility -- not a
/// caller's, who cannot tell the two apart.</para>
///
/// <para>The Windows implementation
/// (<c>AddClipboardFormatListener</c> / <c>WM_CLIPBOARDUPDATE</c>) belongs to
/// the Windows plan. This seam exists so everything above it is testable on any
/// machine.</para>
/// </summary>
public interface IClipboard
{
    /// <summary>
    /// Raised when something *else* changed the clipboard. Never raised for a
    /// change this interface's own <see cref="SetAsync"/> caused.
    /// </summary>
    event EventHandler<ClipboardContent>? ContentChanged;

    /// <summary>The current item, or null when the clipboard holds nothing we handle.</summary>
    Task<ClipboardContent?> GetAsync(CancellationToken ct = default);

    Task SetAsync(ClipboardContent content, CancellationToken ct = default);
}
