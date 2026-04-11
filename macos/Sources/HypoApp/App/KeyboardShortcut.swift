#if canImport(AppKit)
import AppKit
#if canImport(Carbon)
import Carbon
#endif

public struct KeyboardShortcut: Equatable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public static let defaultShowClipboard = KeyboardShortcut(keyCode: 9, carbonModifiers: UInt32(optionKey))

    private static let reservedOptionNumberKeyCodes: Set<UInt32> = [18, 19, 20, 21, 22, 23, 25, 26, 28]

    private struct Descriptor {
        let display: String
        let keyEquivalent: String?
    }

    private static let keyDescriptors: [UInt32: Descriptor] = [
        0: .init(display: "A", keyEquivalent: "a"),
        1: .init(display: "S", keyEquivalent: "s"),
        2: .init(display: "D", keyEquivalent: "d"),
        3: .init(display: "F", keyEquivalent: "f"),
        4: .init(display: "H", keyEquivalent: "h"),
        5: .init(display: "G", keyEquivalent: "g"),
        6: .init(display: "Z", keyEquivalent: "z"),
        7: .init(display: "X", keyEquivalent: "x"),
        8: .init(display: "C", keyEquivalent: "c"),
        9: .init(display: "V", keyEquivalent: "v"),
        11: .init(display: "B", keyEquivalent: "b"),
        12: .init(display: "Q", keyEquivalent: "q"),
        13: .init(display: "W", keyEquivalent: "w"),
        14: .init(display: "E", keyEquivalent: "e"),
        15: .init(display: "R", keyEquivalent: "r"),
        16: .init(display: "Y", keyEquivalent: "y"),
        17: .init(display: "T", keyEquivalent: "t"),
        18: .init(display: "1", keyEquivalent: "1"),
        19: .init(display: "2", keyEquivalent: "2"),
        20: .init(display: "3", keyEquivalent: "3"),
        21: .init(display: "4", keyEquivalent: "4"),
        22: .init(display: "6", keyEquivalent: "6"),
        23: .init(display: "5", keyEquivalent: "5"),
        24: .init(display: "=", keyEquivalent: "="),
        25: .init(display: "9", keyEquivalent: "9"),
        26: .init(display: "7", keyEquivalent: "7"),
        27: .init(display: "-", keyEquivalent: "-"),
        28: .init(display: "8", keyEquivalent: "8"),
        29: .init(display: "0", keyEquivalent: "0"),
        30: .init(display: "]", keyEquivalent: "]"),
        31: .init(display: "O", keyEquivalent: "o"),
        32: .init(display: "U", keyEquivalent: "u"),
        33: .init(display: "[", keyEquivalent: "["),
        34: .init(display: "I", keyEquivalent: "i"),
        35: .init(display: "P", keyEquivalent: "p"),
        37: .init(display: "L", keyEquivalent: "l"),
        38: .init(display: "J", keyEquivalent: "j"),
        39: .init(display: "'", keyEquivalent: "'"),
        40: .init(display: "K", keyEquivalent: "k"),
        41: .init(display: ";", keyEquivalent: ";"),
        42: .init(display: "\\", keyEquivalent: "\\"),
        43: .init(display: ",", keyEquivalent: ","),
        44: .init(display: "/", keyEquivalent: "/"),
        45: .init(display: "N", keyEquivalent: "n"),
        46: .init(display: "M", keyEquivalent: "m"),
        47: .init(display: ".", keyEquivalent: "."),
        50: .init(display: "`", keyEquivalent: "`"),
        65: .init(display: ".", keyEquivalent: "."),
        67: .init(display: "*", keyEquivalent: "*"),
        69: .init(display: "+", keyEquivalent: "+"),
        71: .init(display: "Clear", keyEquivalent: nil),
        75: .init(display: "/", keyEquivalent: "/"),
        76: .init(display: "Enter", keyEquivalent: nil),
        78: .init(display: "-", keyEquivalent: "-"),
        81: .init(display: "=", keyEquivalent: "="),
        82: .init(display: "0", keyEquivalent: "0"),
        83: .init(display: "1", keyEquivalent: "1"),
        84: .init(display: "2", keyEquivalent: "2"),
        85: .init(display: "3", keyEquivalent: "3"),
        86: .init(display: "4", keyEquivalent: "4"),
        87: .init(display: "5", keyEquivalent: "5"),
        88: .init(display: "6", keyEquivalent: "6"),
        89: .init(display: "7", keyEquivalent: "7"),
        91: .init(display: "8", keyEquivalent: "8"),
        92: .init(display: "9", keyEquivalent: "9"),
        96: .init(display: "F5", keyEquivalent: nil),
        97: .init(display: "F6", keyEquivalent: nil),
        98: .init(display: "F7", keyEquivalent: nil),
        99: .init(display: "F3", keyEquivalent: nil),
        100: .init(display: "F8", keyEquivalent: nil),
        101: .init(display: "F9", keyEquivalent: nil),
        103: .init(display: "F11", keyEquivalent: nil),
        109: .init(display: "F10", keyEquivalent: nil),
        111: .init(display: "F12", keyEquivalent: nil),
        118: .init(display: "F4", keyEquivalent: nil),
        120: .init(display: "F2", keyEquivalent: nil),
        122: .init(display: "F1", keyEquivalent: nil),
        123: .init(display: "Left Arrow", keyEquivalent: nil),
        124: .init(display: "Right Arrow", keyEquivalent: nil),
        125: .init(display: "Down Arrow", keyEquivalent: nil),
        126: .init(display: "Up Arrow", keyEquivalent: nil)
    ]

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    public init?(defaultsValue: String) {
        let parts = defaultsValue.split(separator: ":")
        guard parts.count == 2,
              let keyCode = UInt32(parts[0]),
              let modifiers = UInt32(parts[1]) else {
            return nil
        }
        self.init(keyCode: keyCode, carbonModifiers: modifiers)
    }

    public var defaultsValue: String {
        "\(keyCode):\(carbonModifiers)"
    }

    public var displayString: String {
        modifierSymbols + keyDisplay
    }

    var menuItemTitleSuffix: String {
        "(\(displayString.lowercased()))"
    }

    var keyEquivalent: String {
        Self.keyDescriptors[keyCode]?.keyEquivalent ?? ""
    }

    var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    public var isReservedByHypo: Bool {
        carbonModifiers == UInt32(optionKey) && Self.reservedOptionNumberKeyCodes.contains(keyCode)
    }

    static func capture(from event: NSEvent) -> KeyboardShortcut? {
        try? captureResult(from: event).get()
    }

    static func captureResult(from event: NSEvent) -> Result<KeyboardShortcut, ShortcutRegistrationError> {
        guard event.type == .keyDown else { return .failure(.unsupportedKey) }
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            return .failure(.missingModifier)
        }
        guard keyDescriptors[UInt32(event.keyCode)] != nil else {
            return .failure(.unsupportedKey)
        }
        return .success(KeyboardShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers))
    }

    public static func supports(keyCode: UInt32) -> Bool {
        keyDescriptors[keyCode] != nil
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let filtered = flags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if filtered.contains(.command) { carbon |= UInt32(cmdKey) }
        if filtered.contains(.option) { carbon |= UInt32(optionKey) }
        if filtered.contains(.control) { carbon |= UInt32(controlKey) }
        if filtered.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    private var keyDisplay: String {
        Self.keyDescriptors[keyCode]?.display ?? "Key \(keyCode)"
    }

    private var modifierSymbols: String {
        var pieces: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { pieces.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { pieces.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { pieces.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { pieces.append("⌘") }
        return pieces.joined()
    }
}

enum ShortcutRegistrationError: LocalizedError, Equatable {
    case missingModifier
    case unsupportedKey
    case reservedByHypo
    case systemConflict

    var errorDescription: String? {
        switch self {
        case .missingModifier:
            return "Shortcut must include Command, Option, or Control."
        case .unsupportedKey:
            return "That key is not supported for Show Clipboard."
        case .reservedByHypo:
            return "That shortcut is reserved by Hypo for clipboard item quick-paste."
        case .systemConflict:
            return "That shortcut is already in use by macOS or another app."
        }
    }
}

extension Notification.Name {
    static let showClipboardShortcutChanged = Notification.Name("ShowClipboardShortcutChanged")
}
#endif
