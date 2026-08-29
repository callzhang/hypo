using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Hypo.Windows.Clipboard;

[SupportedOSPlatform("windows")]
internal static partial class NativeMethods
{
    internal const uint GmemMoveable = 0x0002;
    internal const uint WmClipboardUpdate = 0x031D;
    internal const uint WmDestroy = 0x0002;

    /// <summary>The parent that makes a window message-only: it never renders and never appears.</summary>
    internal static readonly nint HwndMessage = -3;

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool OpenClipboard(nint hWndNewOwner);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool CloseClipboard();

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool EmptyClipboard();

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial nint GetClipboardData(uint uFormat);

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial nint SetClipboardData(uint uFormat, nint hMem);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool IsClipboardFormatAvailable(uint format);

    [LibraryImport("user32.dll")]
    internal static partial uint GetClipboardSequenceNumber();

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool AddClipboardFormatListener(nint hwnd);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool RemoveClipboardFormatListener(nint hwnd);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    internal static partial nint GlobalAlloc(uint uFlags, nuint dwBytes);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    internal static partial nint GlobalFree(nint hMem);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    internal static partial nint GlobalLock(nint hMem);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GlobalUnlock(nint hMem);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    internal static partial nuint GlobalSize(nint hMem);
}
