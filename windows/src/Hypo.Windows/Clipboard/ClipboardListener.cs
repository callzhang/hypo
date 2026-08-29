using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using System.Text;

namespace Hypo.Windows.Clipboard;

/// <summary>
/// The Windows implementation of <see cref="IClipboard"/>: a message-only
/// window subscribed to <c>WM_CLIPBOARDUPDATE</c>.
///
/// <para><b>AddClipboardFormatListener, not SetClipboardViewer.</b> The old
/// viewer chain relies on every participant forwarding messages correctly, so
/// one misbehaving application anywhere in it silently stops notifications for
/// everyone downstream.</para>
///
/// <para><b>Echo suppression is by sequence number.</b> Windows raises
/// <c>WM_CLIPBOARDUPDATE</c> for our own writes exactly as for anyone else's,
/// and <see cref="IClipboard"/> promises we will not re-publish them --
/// otherwise applying a peer's item sends it straight back and the two devices
/// loop forever. Comparing content instead would be wrong in a subtler way: a
/// peer may legitimately send the same text again a moment later, and a content
/// filter would swallow it.</para>
///
/// <para><b>Every clipboard call runs on the pump thread.</b> Not tidiness --
/// correctness, in two ways CI demonstrated. Recording our own sequence number
/// from a caller's thread races the update it caused: the notification can be
/// handled before the field is assigned, and the echo escapes. And a reader on
/// the pump thread contends with a writer on a caller's thread for a clipboard
/// only one of them can hold, which surfaces as EmptyClipboard failing on a
/// clipboard we thought we owned. Marshalling the work onto the thread that
/// owns the window makes our own update strictly follow our own write, and
/// leaves the retry to handle the only contention that is genuinely someone
/// else's: other processes.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class ClipboardListener : IClipboard, IDisposable
{
    private delegate nint WindowProcedure(nint hwnd, uint message, nint wParam, nint lParam);

    /// <summary>A private message asking the pump to drain <see cref="_work"/>.</summary>
    private const uint WmRunWork = 0x0400 + 1;

    private readonly Thread _pump;
    private readonly TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly WindowProcedure _procedure;
    private readonly System.Collections.Concurrent.ConcurrentQueue<Action> _work = new();

    private nint _hwnd;

    /// <summary>Only ever touched on the pump thread, which is what makes it reliable.</summary>
    private uint _ownSequence;

    private volatile bool _disposed;

    public ClipboardListener()
    {
        _procedure = WindowProc;

        // The window and its message loop must live on one thread: a
        // message-only window only receives messages on the thread that created
        // it, so a loop running anywhere else would never see an update.
        _pump = new Thread(Run) { IsBackground = true, Name = "hypo-clipboard" };
        _pump.SetApartmentState(ApartmentState.STA);
        _pump.Start();

        if (!_ready.Task.Wait(TimeSpan.FromSeconds(5)))
        {
            throw new TimeoutException("The clipboard listener's message loop did not start.");
        }
    }

    public event EventHandler<ClipboardContent>? ContentChanged;

    public Task<ClipboardContent?> GetAsync(CancellationToken ct = default) =>
        OnPump(() =>
        {
            var text = WindowsClipboard.ReadText();
            return text is null ? null : ClipboardFormats.FromText(text);
        });

    public Task SetAsync(ClipboardContent content, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(content);

        if (content.ContentType is not (ContentType.Text or ContentType.Link))
        {
            // Images and files are a later plan; refusing loudly beats writing
            // raw bytes into CF_UNICODETEXT and producing mojibake.
            throw new NotSupportedException($"{content.ContentType} cannot be written yet.");
        }

        var text = Encoding.UTF8.GetString(content.Data);

        return OnPump<object?>(() =>
        {
            // Both statements on the pump thread, so the WM_CLIPBOARDUPDATE the
            // write causes is dispatched afterwards, by which time the sequence
            // number it must be compared against is already recorded.
            _ownSequence = WindowsClipboard.WriteText(text);
            return null;
        });
    }

    /// <summary>Runs <paramref name="work"/> on the thread that owns the window.</summary>
    private Task<T> OnPump<T>(Func<T> work)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);

        _work.Enqueue(() =>
        {
            try
            {
                completion.TrySetResult(work());
            }
            catch (Exception ex)
            {
                completion.TrySetException(ex);
            }
        });

        if (!PostMessageW(_hwnd, WmRunWork, 0, 0))
        {
            completion.TrySetException(new Win32Exception(
                Marshal.GetLastPInvokeError(), "Could not reach the clipboard pump."));
        }

        return completion.Task;
    }

    private void Run()
    {
        try
        {
            _hwnd = CreateMessageOnlyWindow();

            if (!NativeMethods.AddClipboardFormatListener(_hwnd))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "AddClipboardFormatListener failed.");
            }

            _ready.TrySetResult();

            while (!_disposed && GetMessageW(out var message, 0, 0, 0) > 0)
            {
                TranslateMessage(ref message);
                DispatchMessageW(ref message);
            }
        }
        catch (Exception ex)
        {
            _ready.TrySetException(ex);
        }
    }

    private nint WindowProc(nint hwnd, uint message, nint wParam, nint lParam)
    {
        if (message == NativeMethods.WmClipboardUpdate)
        {
            OnClipboardUpdate();
        }
        else if (message == WmRunWork)
        {
            while (_work.TryDequeue(out var work))
            {
                work();
            }
        }

        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private void OnClipboardUpdate()
    {
        // Same thread that performed the write, so this comparison cannot race it.
        if (NativeMethods.GetClipboardSequenceNumber() == _ownSequence)
        {
            // Our own write. Re-publishing it is how two devices end up echoing
            // one item at each other forever.
            return;
        }

        string? text;
        try
        {
            text = WindowsClipboard.ReadText();
        }
        catch (Win32Exception)
        {
            // Someone else was holding the clipboard through every retry.
            // Missing one update is survivable; dying on the pump thread is not.
            return;
        }

        if (text is not null)
        {
            ContentChanged?.Invoke(this, ClipboardFormats.FromText(text));
        }
    }

    private nint CreateMessageOnlyWindow()
    {
        var className = $"HypoClipboard{Environment.ProcessId}{Environment.CurrentManagedThreadId}";

        var windowClass = new WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_procedure),
            hInstance = GetModuleHandleW(null),
            lpszClassName = className,
        };

        if (RegisterClassExW(ref windowClass) == 0)
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "RegisterClassExW failed.");
        }

        var hwnd = CreateWindowExW(
            0, className, className, 0, 0, 0, 0, 0,
            NativeMethods.HwndMessage, 0, windowClass.hInstance, 0);

        return hwnd == 0
            ? throw new Win32Exception(Marshal.GetLastPInvokeError(), "CreateWindowExW failed.")
            : hwnd;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        // Anything still queued will never run; failing it beats leaving a
        // caller awaiting a task that cannot complete.
        while (_work.TryDequeue(out _))
        {
        }

        if (_hwnd != 0)
        {
            // Leaving the listener registered keeps a message-only window alive,
            // and with it the process.
            NativeMethods.RemoveClipboardFormatListener(_hwnd);
            PostMessageW(_hwnd, NativeMethods.WmDestroy, 0, 0);
            DestroyWindow(_hwnd);
            _hwnd = 0;
        }

        _pump.Join(TimeSpan.FromSeconds(2));
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEXW
    {
        public uint cbSize;
        public uint style;
        public nint lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public nint hInstance;
        public nint hIcon;
        public nint hCursor;
        public nint hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
        public nint hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public nint hwnd;
        public uint message;
        public nint wParam;
        public nint lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClassExW(ref WNDCLASSEXW windowClass);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern nint CreateWindowExW(
        uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height,
        nint parent, nint menu, nint instance, nint param);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyWindow(nint hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetMessageW(out MSG message, nint hwnd, uint filterMin, uint filterMax);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TranslateMessage(ref MSG message);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint DispatchMessageW(ref MSG message);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint DefWindowProcW(nint hwnd, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessageW(nint hwnd, uint message, nint wParam, nint lParam);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandleW(string? moduleName);
}
