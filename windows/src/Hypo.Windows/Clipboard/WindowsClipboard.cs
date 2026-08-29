using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Hypo.Windows.Clipboard;

/// <summary>
/// Reading and writing the Win32 clipboard.
///
/// <para><b>Opening retries, and that is not defensive padding.</b>
/// <c>OpenClipboard</c> fails while another process holds it, and on a desktop
/// with Office, a browser and any clipboard manager running, that happens
/// routinely rather than exceptionally. A single attempt yields a client that
/// drops copies now and then for no visible reason, which is far harder to
/// diagnose than an honest error after several tries.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public static class WindowsClipboard
{
    private const int OpenAttempts = 10;
    private static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(20);

    /// <summary>Reads CF_UNICODETEXT, or null when the clipboard holds no text.</summary>
    public static string? ReadText()
    {
        using var _ = Open();

        if (!NativeMethods.IsClipboardFormatAvailable(ClipboardFormats.CfUnicodeText))
        {
            return null;
        }

        var handle = NativeMethods.GetClipboardData(ClipboardFormats.CfUnicodeText);
        if (handle == 0)
        {
            return null;
        }

        var pointer = NativeMethods.GlobalLock(handle);
        if (pointer == 0)
        {
            return null;
        }

        try
        {
            var size = (int)NativeMethods.GlobalSize(handle);
            if (size <= 0)
            {
                return string.Empty;
            }

            var buffer = new byte[size];
            Marshal.Copy(pointer, buffer, 0, size);
            return ClipboardFormats.DecodeUnicodeText(buffer);
        }
        finally
        {
            NativeMethods.GlobalUnlock(handle);
        }
    }

    /// <summary>
    /// Writes CF_UNICODETEXT and returns the clipboard sequence number
    /// afterwards, which the listener uses to recognise -- and ignore -- its own
    /// write.
    /// </summary>
    public static uint WriteText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        var bytes = ClipboardFormats.EncodeUnicodeText(text);

        using var _ = Open();

        // EmptyClipboard before SetClipboardData. Skipping it leaves the
        // previous owner's data in place and is a documented way to leak it.
        if (!NativeMethods.EmptyClipboard())
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "EmptyClipboard failed.");
        }

        var handle = NativeMethods.GlobalAlloc(NativeMethods.GmemMoveable, (nuint)bytes.Length);
        if (handle == 0)
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "GlobalAlloc failed.");
        }

        try
        {
            var pointer = NativeMethods.GlobalLock(handle);
            if (pointer == 0)
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "GlobalLock failed.");
            }

            try
            {
                Marshal.Copy(bytes, 0, pointer, bytes.Length);
            }
            finally
            {
                NativeMethods.GlobalUnlock(handle);
            }

            if (NativeMethods.SetClipboardData(ClipboardFormats.CfUnicodeText, handle) == 0)
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "SetClipboardData failed.");
            }

            // Ownership passed to the clipboard on success; freeing it now would
            // hand the system a dangling handle.
            handle = 0;
        }
        finally
        {
            if (handle != 0)
            {
                NativeMethods.GlobalFree(handle);
            }
        }

        return NativeMethods.GetClipboardSequenceNumber();
    }

    public static uint SequenceNumber() => NativeMethods.GetClipboardSequenceNumber();

    private static ClipboardSession Open()
    {
        for (var attempt = 0; attempt < OpenAttempts; attempt++)
        {
            if (NativeMethods.OpenClipboard(0))
            {
                return new ClipboardSession();
            }

            Thread.Sleep(RetryDelay);
        }

        throw new Win32Exception(
            Marshal.GetLastPInvokeError(),
            $"Could not open the clipboard after {OpenAttempts} attempts; another " +
            "process is holding it. This is normally transient.");
    }

    private readonly struct ClipboardSession : IDisposable
    {
        public void Dispose() => NativeMethods.CloseClipboard();
    }
}
