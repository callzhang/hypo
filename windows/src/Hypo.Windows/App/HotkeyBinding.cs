namespace Hypo.Windows.App;

/// <summary>Modifier keys, matching the Win32 <c>MOD_*</c> values.</summary>
[Flags]
public enum HotkeyModifiers
{
    None = 0,
    Alt = 0x0001,
    Control = 0x0002,
    Shift = 0x0004,
    Windows = 0x0008,

    /// <summary>Stops the key repeating while held, which a popup does not want.</summary>
    NoRepeat = 0x4000,
}

/// <summary>
/// A key combination, and how to describe it.
///
/// <para>Separate from the registration so the parsing, the formatting and the
/// rule about <c>Win+V</c> can be tested anywhere; only the registering needs
/// Windows.</para>
/// </summary>
public sealed record HotkeyBinding
{
    /// <summary>
    /// Alt+V by default, matching macOS's Option+V.
    ///
    /// <para><c>Win+V</c> is deliberately not the default and cannot be chosen:
    /// Windows reserves it for its own clipboard history, and
    /// <c>RegisterHotKey</c> fails rather than overriding it. Offering it would
    /// be offering a setting that cannot work.</para>
    /// </summary>
    public static HotkeyBinding Default { get; } = new()
    {
        Modifiers = HotkeyModifiers.Alt,
        Key = 'V',
    };

    public required HotkeyModifiers Modifiers { get; init; }

    /// <summary>
    /// The virtual-key code. For letters and digits this is the character
    /// itself, which is what Windows uses for them.
    /// </summary>
    public required int Key { get; init; }

    /// <summary>True when Windows will never grant this combination.</summary>
    public bool IsReserved =>
        Modifiers.HasFlag(HotkeyModifiers.Windows) && Key is 'V';

    /// <summary>How it reads in a menu: "Alt+V".</summary>
    public override string ToString()
    {
        var parts = new List<string>(4);

        if (Modifiers.HasFlag(HotkeyModifiers.Control)) parts.Add("Ctrl");
        if (Modifiers.HasFlag(HotkeyModifiers.Alt)) parts.Add("Alt");
        if (Modifiers.HasFlag(HotkeyModifiers.Shift)) parts.Add("Shift");
        if (Modifiers.HasFlag(HotkeyModifiers.Windows)) parts.Add("Win");

        parts.Add(Key switch
        {
            >= 'A' and <= 'Z' or >= '0' and <= '9' => ((char)Key).ToString(),
            >= FirstFunctionKey and <= LastFunctionKey => $"F{Key - FirstFunctionKey + 1}",
            _ => $"0x{Key:X2}",
        });

        return string.Join('+', parts);
    }

    /// <summary>
    /// Reads a binding written the way <see cref="ToString"/> writes one.
    ///
    /// <para>Returns null rather than throwing: this comes out of a settings
    /// file a person may have edited, and a typo there should cost the hotkey,
    /// not the application.</para>
    /// </summary>
    /// <summary>VK_F1. The function keys run consecutively from here to F24.</summary>
    private const int FirstFunctionKey = 0x70;

    private const int LastFunctionKey = FirstFunctionKey + 23;

    /// <summary>
    /// A single key name to its virtual-key code, or null for anything this does
    /// not recognise.
    ///
    /// <para>Letters and digits, plus F1 to F24 -- the combinations someone
    /// reaching for a spare shortcut would try. Deliberately not the punctuation
    /// keys, whose codes depend on the keyboard layout.</para>
    /// </summary>
    private static int? KeyFrom(string part)
    {
        if (part.Length == 1 && part[0] is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9')
        {
            return char.ToUpperInvariant(part[0]);
        }

        if (part.Length is 2 or 3
            && part[0] is 'F' or 'f'
            && int.TryParse(part.AsSpan(1), out var number)
            && number is >= 1 and <= 24)
        {
            return FirstFunctionKey + number - 1;
        }

        return null;
    }

    public static HotkeyBinding? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        var modifiers = HotkeyModifiers.None;
        int? key = null;

        foreach (var part in text.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            switch (part.ToUpperInvariant())
            {
                case "CTRL" or "CONTROL": modifiers |= HotkeyModifiers.Control; break;
                case "ALT": modifiers |= HotkeyModifiers.Alt; break;
                case "SHIFT": modifiers |= HotkeyModifiers.Shift; break;
                case "WIN" or "WINDOWS": modifiers |= HotkeyModifiers.Windows; break;

                default:
                    var parsed = KeyFrom(part);
                    if (parsed is null)
                    {
                        return null;
                    }

                    // Two keys is not a combination anyone meant.
                    if (key is not null)
                    {
                        return null;
                    }

                    key = parsed;
                    break;
            }
        }

        // A bare letter with no modifier would swallow that key everywhere.
        return key is null || modifiers == HotkeyModifiers.None
            ? null
            : new HotkeyBinding { Modifiers = modifiers, Key = key.Value };
    }
}
