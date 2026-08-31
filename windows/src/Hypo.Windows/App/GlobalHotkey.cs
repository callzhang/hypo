using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Hypo.Windows.App;

/// <summary>
/// A system-wide key combination that opens the clipboard history.
///
/// <para>Without one, reaching the history means finding the tray icon and
/// clicking through a menu, which is slower than opening the application you
/// copied from again. A clipboard manager is the hotkey.</para>
///
/// <para>Registration can fail, and usually for a reason worth telling someone:
/// another application already holds the combination. That is surfaced rather
/// than swallowed -- a hotkey that silently does nothing is indistinguishable
/// from a broken application.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public sealed partial class GlobalHotkey : IDisposable
{
    private const uint WmHotkey = 0x0312;
    private const uint WmClose = 0x0010;
    private const int Id = 0xB0B;

    private readonly Thread? _pump;
    private readonly TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly WindowProcedure _procedure;

    private nint _hwnd;
    private volatile bool _disposed;

    private delegate nint WindowProcedure(nint hwnd, uint message, nint wParam, nint lParam);

    public GlobalHotkey(HotkeyBinding binding)
    {
        ArgumentNullException.ThrowIfNull(binding);

        Binding = binding;
        _procedure = WindowProc;

        if (binding.IsReserved)
        {
            // Windows will refuse this one whatever we do, and saying why is
            // more useful than the error code it would produce.
            Failure = $"{binding} is reserved by Windows for its own clipboard history.";
            return;
        }

        _pump = new Thread(Run) { IsBackground = true, Name = "hypo-hotkey" };
        _pump.SetApartmentState(ApartmentState.STA);
        _pump.Start();

        // Registration is the constructor's job: a caller that gets an object back
        // should already know whether the shortcut works.
        if (!_ready.Task.Wait(TimeSpan.FromSeconds(5)))
        {
            Failure = "The shortcut could not be registered in time.";
        }
    }

    /// <summary>Raised, off the caller's thread, when the combination is pressed.</summary>
    public event EventHandler? Pressed;

    public HotkeyBinding Binding { get; }

    /// <summary>Why the hotkey is not working, or null when it is.</summary>
    public string? Failure { get; private set; }

    public bool IsRegistered => Failure is null && _hwnd != 0;

    private void Run()
    {
        try
        {
            _hwnd = CreateMessageOnlyWindow();

            // NoRepeat: holding the keys should open the window once, not open
            // it as fast as the keyboard repeats.
            if (!RegisterHotKey(_hwnd, Id, (uint)(Binding.Modifiers | HotkeyModifiers.NoRepeat), (uint)Binding.Key))
            {
                var error = Marshal.GetLastPInvokeError();

                // 1409 is ERROR_HOTKEY_ALREADY_REGISTERED, which is the common
                // case and the only one a user can act on.
                Failure = error == 1409
                    ? $"{Binding} is already taken by another application."
                    : new Win32Exception(error).Message;
            }

            _ready.TrySetResult();

            while (GetMessageW(out var message, 0, 0, 0) > 0)
            {
                DispatchMessageW(ref message);
            }
        }
        catch (Exception ex)
        {
            Failure = ex.Message;
            _ready.TrySetResult();
        }
    }

    private nint WindowProc(nint hwnd, uint message, nint wParam, nint lParam)
    {
        if (message == WmHotkey && wParam == Id)
        {
            Pressed?.Invoke(this, EventArgs.Empty);
            return 0;
        }

        if (message == WmClose)
        {
            // Both of these are thread-affine -- the hotkey belongs to the thread
            // that registered it and the window to the thread that created it --
            // so Dispose posts here rather than doing the work itself.
            UnregisterHotKey(hwnd, Id);
            DestroyWindow(hwnd);
            PostQuitMessage(0);
            return 0;
        }

        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private nint CreateMessageOnlyWindow()
    {
        var className = $"HypoHotkey{Environment.ProcessId}{Environment.CurrentManagedThreadId}";

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

        var hwnd = CreateWindowExW(0, className, className, 0, 0, 0, 0, 0, -3, 0, windowClass.hInstance, 0);

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

        if (_hwnd != 0)
        {
            // Left registered, the combination stays claimed for the session and
            // the next launch cannot have it.
            PostMessageW(_hwnd, WmClose, 0, 0);
            _hwnd = 0;
        }

        _pump?.Join(TimeSpan.FromSeconds(2));
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

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterHotKey(nint hWnd, int id, uint modifiers, uint virtualKey);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnregisterHotKey(nint hWnd, int id);

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessageW(nint hwnd, uint message, nint wParam, nint lParam);

    [LibraryImport("user32.dll")]
    private static partial void PostQuitMessage(int exitCode);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClassExW(ref WNDCLASSEXW windowClass);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern nint CreateWindowExW(
        uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, nint parent, nint menu, nint instance, nint param);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyWindow(nint hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetMessageW(out MSG message, nint hwnd, uint filterMin, uint filterMax);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint DispatchMessageW(ref MSG message);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint DefWindowProcW(nint hwnd, uint message, nint wParam, nint lParam);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandleW(string? moduleName);
}
