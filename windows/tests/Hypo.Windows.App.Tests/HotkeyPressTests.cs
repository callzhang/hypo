using System.Runtime.InteropServices;
using Hypo.Windows.App;

namespace Hypo.Windows.App.Tests;

/// <summary>
/// The one thing the unit tests cannot show: that pressing the keys does
/// something.
///
/// <para>Registration succeeding is not the same claim. This synthesises the
/// keystrokes and waits for the event, so a mistake in the message pump -- the
/// window never created, the loop never running, the wrong id -- fails here
/// rather than on someone's desk.</para>
/// </summary>
public class HotkeyPressTests
{
    // Deliberately obscure: it has to be free on whatever machine runs this, and
    // it will really be pressed, so it must not do anything if it leaks.
    private static readonly HotkeyBinding Unlikely = HotkeyBinding.Parse("Ctrl+Alt+Shift+F7")!;

    [SkippableFact]
    public void PressingTheKeysRaisesIt()
    {
        Skip.IfNot(OperatingSystem.IsWindows());

        using var hotkey = new GlobalHotkey(Unlikely);
        Skip.IfNot(hotkey.IsRegistered, hotkey.Failure ?? "not registered");

        using var pressed = new ManualResetEventSlim();
        hotkey.Pressed += (_, _) => pressed.Set();

        Press();

        Assert.True(pressed.Wait(TimeSpan.FromSeconds(5)), "the shortcut registered but pressing it did nothing");
    }

    [SkippableFact]
    public void AfterDisposeThePressGoesNowhere()
    {
        Skip.IfNot(OperatingSystem.IsWindows());

        var raised = 0;
        var hotkey = new GlobalHotkey(Unlikely);
        Skip.IfNot(hotkey.IsRegistered, hotkey.Failure ?? "not registered");

        hotkey.Pressed += (_, _) => Interlocked.Increment(ref raised);
        hotkey.Dispose();

        Press();
        Thread.Sleep(500);

        // If this fails the combination is still claimed process-wide, and the
        // next launch of the application cannot have it.
        Assert.Equal(0, Volatile.Read(ref raised));
    }

    private static void Press()
    {
        const ushort Control = 0x11, Alt = 0x12, Shift = 0x10, F7 = 0x76;

        Send(Control, up: false);
        Send(Alt, up: false);
        Send(Shift, up: false);
        Send(F7, up: false);
        Send(F7, up: true);
        Send(Shift, up: true);
        Send(Alt, up: true);
        Send(Control, up: true);
    }

    private static void Send(ushort key, bool up)
    {
        var input = new INPUT
        {
            type = 1, // INPUT_KEYBOARD
            ki = new KEYBDINPUT { wVk = key, dwFlags = up ? 2u : 0u },
        };

        SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public KEYBDINPUT ki;
        // KEYBDINPUT is the smallest member of the union; MOUSEINPUT is larger,
        // and SendInput measures the whole structure.
        public int padding0;
        public int padding1;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public nint dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
}
