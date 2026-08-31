using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

/// <summary>
/// The registration itself, which needs a real Windows message queue.
/// </summary>
public class GlobalHotkeyTests
{
    [SkippableFact]
    public void TheDefaultRegisters()
    {
        Skip.IfNot(OperatingSystem.IsWindows());

        using var hotkey = new GlobalHotkey(HotkeyBinding.Default);

        Assert.Null(hotkey.Failure);
        Assert.True(hotkey.IsRegistered);
    }

    [SkippableFact]
    public void ASecondClaimOnTheSameKeysSaysWhoHasIt()
    {
        Skip.IfNot(OperatingSystem.IsWindows());

        var binding = HotkeyBinding.Parse("Ctrl+Alt+Shift+F9")!;
        using var first = new GlobalHotkey(binding);
        Skip.IfNot(first.IsRegistered, "something else on this machine already holds the combination");

        using var second = new GlobalHotkey(binding);

        // A hotkey that silently does nothing is indistinguishable from a broken
        // application, so the reason has to survive as far as the UI.
        Assert.False(second.IsRegistered);
        Assert.Contains("already taken", second.Failure);
    }

    [SkippableFact]
    public void ReleasingItLetsTheNextLaunchHaveIt()
    {
        Skip.IfNot(OperatingSystem.IsWindows());

        var binding = HotkeyBinding.Parse("Ctrl+Alt+Shift+F10")!;

        using (var first = new GlobalHotkey(binding))
        {
            Skip.IfNot(first.IsRegistered, "something else on this machine already holds the combination");
        }

        using var second = new GlobalHotkey(binding);

        Assert.True(second.IsRegistered);
    }

    [SkippableFact]
    public void TheReservedCombinationIsRefusedWithoutAskingWindows()
    {
        Skip.IfNot(OperatingSystem.IsWindows());

        using var hotkey = new GlobalHotkey(HotkeyBinding.Parse("Win+V")!);

        Assert.False(hotkey.IsRegistered);
        Assert.Contains("reserved by Windows", hotkey.Failure);
    }
}
