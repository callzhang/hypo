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

    /// <summary>
    /// Above the protocol's 20 MB envelope ceiling there is no point reading the
    /// file at all -- the send would be refused after the copy.
    /// </summary>
    private const long MaxFileBytes = 20L * 1024 * 1024;

    private readonly Thread _pump;
    private readonly TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly WindowProcedure _procedure;
    private readonly System.Collections.Concurrent.ConcurrentQueue<Action> _work = new();

    private readonly string _receivedFiles;

    /// <summary>
    /// How far written items may travel. Settable because the user can change it
    /// while the application runs, and a setting that needed a restart would be
    /// one people assume did not work.
    /// </summary>
    public ClipboardPrivacy Privacy { get; set; } = ClipboardPrivacy.Private;

    private nint _hwnd;

    /// <summary>
    /// Sequence numbers our own writes produced. A short history rather than a
    /// single value, because Windows does not promise exactly one
    /// WM_CLIPBOARDUPDATE per change, and a second notification for a write we
    /// already recognised would otherwise be forwarded as a peer's.
    /// Only ever touched on the pump thread.
    /// </summary>
    private readonly Queue<uint> _ownSequences = new();

    private volatile bool _disposed;

    /// <param name="receivedFilesDirectory">
    /// Where a file from a peer is written before being put on the clipboard.
    /// The clipboard carries paths, not bytes, so the bytes have to land
    /// somewhere real first.
    /// </param>
    public ClipboardListener(string? receivedFilesDirectory = null)
    {
        _receivedFiles = receivedFilesDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Hypo",
            "received");

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

    /// <summary>
    /// Raised when an image was too large to send even after compressing.
    ///
    /// <para>Reported rather than dropped: an image that silently fails to sync
    /// looks exactly like the application being broken, and the user is the only
    /// one who can do anything about it.</para>
    /// </summary>
    public event EventHandler<string>? OversizedImage;

    public Task<ClipboardContent?> GetAsync(CancellationToken ct = default) => OnPump(ReadCurrent);

    /// <summary>
    /// Reads whatever the clipboard holds that we understand.
    ///
    /// <para>Images are checked first. An application that copies a picture
    /// usually also puts a text representation alongside it -- a filename, a
    /// URL -- and taking the text would sync the label instead of the
    /// picture.</para>
    /// </summary>
    private ClipboardContent? ReadCurrent()
    {
        var png = WindowsClipboard.ReadPng();
        if (png is { Length: > 0 })
        {
            // Shrunk here rather than at send time, so what goes into the
            // history is what the peer will get -- otherwise the local copy and
            // the synced one quietly differ.
            var fitted = ImageCompressor.Fit(png);

            if (fitted.Refused)
            {
                OversizedImage?.Invoke(this, fitted.Refusal!);
                return null;
            }

            return new ClipboardContent { ContentType = ContentType.Image, Data = fitted.Data };
        }

        // Files before text: copying a file in Explorer also puts its path on the
        // clipboard as text, and syncing the path string to another machine gives
        // the peer something it cannot open.
        var paths = WindowsClipboard.ReadFilePaths();
        if (paths.Count > 0)
        {
            var file = ReadFile(paths[0]);
            if (file is not null)
            {
                return file;
            }
        }

        var text = WindowsClipboard.ReadText();
        return text is null ? null : ClipboardFormats.FromText(text);
    }

    /// <summary>
    /// Loads one file's bytes for sending.
    ///
    /// <para>The protocol carries a single file per message, so a multi-file
    /// selection sends the first. Sending several as one blob would need a
    /// container format the other clients do not read.</para>
    /// </summary>
    private static ClipboardContent? ReadFile(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > MaxFileBytes)
            {
                return null;
            }

            return new ClipboardContent
            {
                ContentType = ContentType.File,
                Data = File.ReadAllBytes(path),
                // Both spellings: protocol.md documents "filename" and the Android
                // client writes and prefers "file_name", so a file that passes
                // through either keeps its name.
                Metadata = new Dictionary<string, string>
                {
                    ["file_name"] = Path.GetFileName(path),
                    ["filename"] = Path.GetFileName(path),
                    ["size"] = info.Length.ToString(System.Globalization.CultureInfo.InvariantCulture),
                },
            };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // A file we cannot read is not a reason to stop syncing text.
            return null;
        }
    }

    public Task SetAsync(ClipboardContent content, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(content);

        if (content.ContentType is ContentType.File)
        {
            return WriteFileAsync(content);
        }

        if (content.ContentType is ContentType.Image && !ClipboardFormats.LooksLikePng(content.Data))
        {
            throw new NotSupportedException("Only PNG images can be placed on the clipboard.");
        }

        var text = content.ContentType is ContentType.Image
            ? null
            : Encoding.UTF8.GetString(content.Data);

        return OnPump<object?>(() =>
        {
            // Both statements on the pump thread, so the WM_CLIPBOARDUPDATE the
            // write causes is dispatched afterwards, by which time the sequence
            // number it must be compared against is already recorded.
            _ownSequences.Enqueue(text is null
                ? WindowsClipboard.WritePng(content.Data, Privacy)
                : WindowsClipboard.WriteText(text, Privacy));
            while (_ownSequences.Count > 8)
            {
                _ownSequences.Dequeue();
            }

            return null;
        });
    }

    /// <summary>
    /// Writes a peer's file to disk and puts its path on the clipboard.
    ///
    /// <para>The name comes from another device, so it is reduced to a leaf and
    /// stripped of characters Windows forbids before anything is created --
    /// otherwise a peer could name a file <c>..\..\autorun.inf</c> and choose
    /// where it lands.</para>
    /// </summary>
    private Task WriteFileAsync(ClipboardContent content)
    {
        Directory.CreateDirectory(_receivedFiles);

        var name = ClipboardFiles.SafeFileName(content.FileName);
        var path = Path.Combine(_receivedFiles, name);

        // Never overwrite: a peer resending "report.pdf" must not replace the one
        // already sitting there, which the user may not have opened yet.
        if (File.Exists(path))
        {
            var stem = Path.GetFileNameWithoutExtension(name);
            var extension = Path.GetExtension(name);
            path = Path.Combine(
                _receivedFiles,
                $"{stem}-{DateTime.UtcNow:yyyyMMdd-HHmmss-fff}{extension}");
        }

        File.WriteAllBytes(path, content.Data);

        return OnPump<object?>(() =>
        {
            _ownSequences.Enqueue(WindowsClipboard.WriteFilePaths([path], Privacy));
            while (_ownSequences.Count > 8)
            {
                _ownSequences.Dequeue();
            }

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
        if (_ownSequences.Contains(NativeMethods.GetClipboardSequenceNumber()))
        {
            // Our own write. Re-publishing it is how two devices end up echoing
            // one item at each other forever.
            return;
        }

        ClipboardContent? content;
        try
        {
            content = ReadCurrent();
        }
        catch (Win32Exception)
        {
            // Someone else was holding the clipboard through every retry.
            // Missing one update is survivable; dying on the pump thread is not.
            return;
        }

        if (content is not null)
        {
            ContentChanged?.Invoke(this, content);
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
