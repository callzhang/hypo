using Hypo.Windows.App;

namespace Hypo.Windows.Tests;

public class HotkeyBindingTests
{
    [Fact]
    public void TheDefaultIsAltV()
    {
        // The spec's choice: Win+V belongs to Windows, so Alt+V is the nearest
        // thing to the muscle memory people already have.
        Assert.Equal("Alt+V", HotkeyBinding.Default.ToString());
    }

    [Theory]
    [InlineData("Alt+V")]
    [InlineData("Ctrl+Shift+V")]
    [InlineData("Ctrl+Alt+H")]
    public void WhatItPrintsIsWhatItReads(string text)
    {
        Assert.Equal(text, HotkeyBinding.Parse(text)!.ToString());
    }

    [Theory]
    [InlineData("alt+v")]
    [InlineData("ALT + V")]
    [InlineData("Alt +v")]
    public void TypingIsForgiven(string text)
    {
        Assert.Equal(HotkeyBinding.Default, HotkeyBinding.Parse(text));
    }

    [Theory]
    [InlineData("Control+V", HotkeyModifiers.Control)]
    [InlineData("Ctrl+V", HotkeyModifiers.Control)]
    [InlineData("Win+V", HotkeyModifiers.Windows)]
    [InlineData("Windows+V", HotkeyModifiers.Windows)]
    public void TheUsualSpellingsAllWork(string text, HotkeyModifiers expected)
    {
        Assert.Equal(expected, HotkeyBinding.Parse(text)!.Modifiers);
    }

    [Theory]
    [InlineData("Ctrl+Alt+Shift+F7", 0x76)]
    [InlineData("Ctrl+F1", 0x70)]
    [InlineData("Alt+F12", 0x7B)]
    [InlineData("Ctrl+Alt+F24", 0x87)]
    [InlineData("Ctrl+Alt+7", '7')]
    [InlineData("Alt+F", 'F')]   // one character: the letter, not F-something
    public void FunctionKeysAndDigitsAreKeysToo(string text, int expected)
    {
        // Not decoration: the letters are mostly spoken for, so a spare
        // combination is usually a function key.
        var binding = HotkeyBinding.Parse(text);

        Assert.NotNull(binding);
        Assert.Equal(expected, binding.Key);
        Assert.Equal(text, binding.ToString());
    }

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("V")]           // no modifier -- would swallow the letter V
    [InlineData("Alt+")]
    [InlineData("Alt+Ctrl")]    // all modifier, no key
    [InlineData("Meta+V")]
    [InlineData("Alt+VV")]
    [InlineData("Alt+F0")]
    [InlineData("Alt+F25")]
    [InlineData("Alt+;")]   // punctuation: the code depends on the layout
    public void NonsenseIsNullRatherThanAnException(string? text)
    {
        // This value comes out of a settings file a person can hand-edit, so a
        // typo has to degrade to the default, not stop the application.
        Assert.Null(HotkeyBinding.Parse(text));
    }

    [Fact]
    public void WinVIsKnownToBeReserved()
    {
        // Windows will refuse to register it. Saying so beats surfacing the
        // error code it would produce.
        Assert.True(HotkeyBinding.Parse("Win+V")!.IsReserved);
        Assert.False(HotkeyBinding.Default.IsReserved);
        Assert.False(HotkeyBinding.Parse("Win+H")!.IsReserved);
    }
}
