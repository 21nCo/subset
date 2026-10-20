import Foundation

/// The modifier keys Hop distinguishes. The host maps the platform's event flags onto these; Caps Lock, Fn and the
/// keypad flag (which arrow keys carry) are not modifiers here and never affect a match.
public struct ModifierMask: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ModifierMask(rawValue: 1 << 0)
    public static let control = ModifierMask(rawValue: 1 << 1)
    public static let option = ModifierMask(rawValue: 1 << 2)
    public static let command = ModifierMask(rawValue: 1 << 3)

    /// Every modifier Hop distinguishes; other bits in a raw value are ignored.
    public static let all: ModifierMask = [.shift, .control, .option, .command]

    /// The modifiers among a keyboard event's raw `CGEventFlags`, whose device-independent bits are fixed in
    /// CGEventTypes.h: Shift 0x20000, Control 0x40000, Option 0x80000, Command 0x100000. Caps Lock (0x10000), the keypad
    /// flag (0x200000), Help (0x400000), Fn (0x800000), and the device-dependent left/right bits are dropped.
    public init(eventFlags: UInt64) {
        self = []
        if eventFlags & 0x20000 != 0 { insert(.shift) }
        if eventFlags & 0x40000 != 0 { insert(.control) }
        if eventFlags & 0x80000 != 0 { insert(.option) }
        if eventFlags & 0x100000 != 0 { insert(.command) }
    }
}

/// Virtual key codes (the hardware-independent codes macOS reports for the US layout positions) that Hop handles.
public enum KeyCode {
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let grave: UInt16 = 0x32
    public static let escape: UInt16 = 0x35
    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E

    /// The modifier keys themselves (Command, Shift, Caps Lock, Option, Control, their right-hand twins, and Fn).
    /// They arrive as flag changes, not key presses, so none of them can be a shortcut key.
    public static let modifierKeys: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]

    /// The keys an active switch already gives a meaning with the holding modifier (Esc cancels, ← and → step, ↑ and ↓
    /// move by row), so none of them can be the shortcut key.
    public static let reserved: Set<UInt16> = [escape, leftArrow, rightArrow, upArrow, downArrow]
}

/// The hold-to-switch shortcut: hold `holdModifier` and press `keyCode` to switch forward; add Shift to switch
/// backward. Only Option or Control may be held. Command is not allowed because taking over ⌘Tab needs a private API,
/// and Shift is reserved for the backward direction.
public struct Shortcut: Sendable, Hashable {
    public enum Invalid: Error, Equatable {
        /// The holding modifier is not exactly Option or exactly Control.
        case holdModifier(ModifierMask)
        /// The key is a modifier key, Esc (which cancels a switch), or an arrow key (which moves its selection).
        case keyCode(UInt16)
    }

    public let holdModifier: ModifierMask
    public let keyCode: UInt16

    /// The default: hold ⌥ and press Tab, or ⌥⇧Tab to go backward.
    public static let `default` = Shortcut(validated: .option, keyCode: KeyCode.tab)

    public init(holdModifier: ModifierMask, keyCode: UInt16) throws(Invalid) {
        guard holdModifier == .option || holdModifier == .control else { throw .holdModifier(holdModifier) }
        // Key codes are 7-bit on every Mac keyboard; a larger value cannot come from a key press.
        guard keyCode < 0x80, !KeyCode.reserved.contains(keyCode), !KeyCode.modifierKeys.contains(keyCode) else {
            throw .keyCode(keyCode)
        }
        self.holdModifier = holdModifier
        self.keyCode = keyCode
    }

    private init(validated holdModifier: ModifierMask, keyCode: UInt16) {
        self.holdModifier = holdModifier
        self.keyCode = keyCode
    }

    /// Modifiers that, together with `keyCode`, start a forward switch.
    public var forwardModifiers: ModifierMask { holdModifier }
    /// Modifiers that, together with `keyCode`, start a backward switch.
    public var backwardModifiers: ModifierMask { holdModifier.union(.shift) }

    /// The holding modifier's symbol: "⌥" or "⌃".
    public var modifierSymbol: String { holdModifier == .control ? "⌃" : "⌥" }

    /// The key's name, such as "Tab". Keys without a name here (the Settings window, SET-95, names the rest) show
    /// their code.
    public var keyName: String {
        switch keyCode {
        case KeyCode.tab: "Tab"
        case KeyCode.space: "Space"
        case KeyCode.grave: "`"
        default: "key \(keyCode)"
        }
    }

    /// The shortcut as menus write it, such as "⌥Tab".
    public var displayName: String { modifierSymbol + keyName }
}

/// Reads the shortcut from the app's user defaults. The Settings window (SET-95) writes these keys; until then they
/// are absent and the default applies. A missing, malformed or disallowed stored value also yields the default, so a
/// bad setting can never leave Hop without a shortcut or holding ⌘.
public struct ShortcutStore {
    public static let holdModifierKey = "shortcut.holdModifier"
    public static let keyCodeKey = "shortcut.keyCode"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var shortcut: Shortcut {
        guard
            let modifier = defaults.object(forKey: Self.holdModifierKey) as? Int,
            let code = defaults.object(forKey: Self.keyCodeKey) as? Int,
            let keyCode = UInt16(exactly: code),
            let stored = try? Shortcut(holdModifier: ModifierMask(rawValue: modifier), keyCode: keyCode)
        else { return .default }
        return stored
    }
}
