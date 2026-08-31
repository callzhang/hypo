using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Hypo.Windows.Clipboard;

/// <summary>
/// Remembers which window the user was working in, and gives focus back to it.
///
/// <para>Without this the history window is inert: someone picks an entry to
/// paste, focus stays with a window that has just hidden itself, and the paste
/// goes nowhere. The point of a clipboard history is the keystroke immediately
/// after choosing something.</para>
///
/// <para><c>SetForegroundWindow</c> is subject to the foreground lock -- Windows
/// refuses it from a process that did not just receive input -- so the input
/// queues are attached first, which is the documented remedy and the reason this
/// is more than one call.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public sealed partial class ForegroundHandoff
{
    private nint _previous;

    /// <summary>Whether there is a window to go back to.</summary>
    public bool HasSomewhereToReturn => _previous != 0;

    /// <summary>
    /// Records the foreground window. Call before showing anything, since
    /// showing is what takes the foreground away.
    /// </summary>
    public void Capture()
    {
        var foreground = GetForegroundWindow();

        // Ours, or nothing at all. Returning focus to our own window would leave
        // the user where they already are; recording zero means "do not try".
        _previous = foreground != 0 && GetWindowThreadProcessId(foreground, out var pid) != 0
                    && pid != (uint)Environment.ProcessId
            ? foreground
            : 0;
    }

    /// <summary>
    /// Puts focus back where it was, and forgets it.
    ///
    /// <para>Returns false when there was nowhere to go or Windows refused,
    /// which callers may want to know but none can do anything about.</para>
    /// </summary>
    public bool Return()
    {
        var target = _previous;
        _previous = 0;

        if (target == 0 || !IsWindow(target))
        {
            // The application the user came from may have closed while the
            // history window was open.
            return false;
        }

        var ours = GetCurrentThreadId();
        var theirs = GetWindowThreadProcessId(target, out _);

        if (theirs == 0)
        {
            return false;
        }

        // Attaching the queues is what lifts the foreground lock. Without it
        // SetForegroundWindow succeeds silently and does nothing, which is the
        // failure mode that makes this look like it works until someone tries
        // to paste.
        var attached = ours != theirs && AttachThreadInput(ours, theirs, true);

        try
        {
            return SetForegroundWindow(target);
        }
        finally
        {
            if (attached)
            {
                AttachThreadInput(ours, theirs, false);
            }
        }
    }

    [LibraryImport("user32.dll")]
    private static partial nint GetForegroundWindow();

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(nint hWnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsWindow(nint hWnd);

    [LibraryImport("user32.dll")]
    private static partial uint GetWindowThreadProcessId(nint hWnd, out uint processId);

    [LibraryImport("kernel32.dll")]
    private static partial uint GetCurrentThreadId();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AttachThreadInput(uint attaching, uint attachTo, [MarshalAs(UnmanagedType.Bool)] bool attach);
}
