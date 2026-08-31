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

    /// <summary>The virtual-key code. For letters this is the uppercase character.</summary>
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

        parts.Add(Key is >= 'A' and <= 'Z' ? ((char)Key).ToString() : $"0x{Key:X2}");

        return string.Join('+', parts);
    }

    /// <summary>
    /// Reads a binding written the way <see cref="ToString"/> writes one.
    ///
    /// <para>Returns null rather than throwing: this comes out of a settings
    /// file a person may have edited, and a typo there should cost the hotkey,
    /// not the application.</para>
    /// </summary>
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
                    if (part.Length != 1 || part[0] is not (>= 'a' and <= 'z' or >= 'A' and <= 'Z'))
                    {
                        return null;
                    }

                    // Two keys is not a combination anyone meant.
                    if (key is not null)
                    {
                        return null;
                    }

                    key = char.ToUpperInvariant(part[0]);
                    break;
            }
        }

        // A bare letter with no modifier would swallow that key everywhere.
        return key is null || modifiers == HotkeyModifiers.None
            ? null
            : new HotkeyBinding { Modifiers = modifiers, Key = key.Value };
    }
}
