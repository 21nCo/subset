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
    public static let grave: UInt16 = 0x32
    public static let escape: UInt16 = 0x35
    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E
}

/// The hold-to-switch shortcut: hold `holdModifier` and press `keyCode` to switch forward; add Shift to switch
/// backward. Only Option or Control may be held, and only Tab or ` (the key left of 1 on a US keyboard) pressed.
/// Command is not allowed because taking over ⌘Tab needs a private API, and Shift is reserved for the backward
/// direction.
public struct Shortcut: Sendable, Hashable {
    /// Why a combination cannot be a shortcut. `reason` says so in the Settings window.
    public enum Invalid: Error, Equatable, Sendable {
        /// ⌘ is among the modifiers.
        case command
        /// Neither ⌥ nor ⌃ is held.
        case noHoldModifier
        /// Both ⌥ and ⌃ are held.
        case bothHoldModifiers
        /// ⇧ is held; it reverses the direction, so it cannot be part of the shortcut.
        case shift
        /// The key is not Tab or `.
        case key(UInt16)
        /// The combination is the same-app shortcut.
        case sameAppShortcut(Shortcut)

        public var reason: String {
            switch self {
            case .command: "⌘ can't be used: switching with ⌘Tab needs a private macOS API."
            case .noHoldModifier: "Hold ⌥ or ⌃ while you press the key."
            case .bothHoldModifiers: "Hold either ⌥ or ⌃, not both."
            case .shift: "⇧ switches backward, so it can't be part of the shortcut."
            case .key: "The key must be Tab or `."
            case let .sameAppShortcut(shortcut): "\(shortcut.displayName) is the same-app shortcut."
            }
        }
    }

    public let holdModifier: ModifierMask
    public let keyCode: UInt16

    /// The keys a shortcut may use.
    public static let allowedKeys: Set<UInt16> = [KeyCode.tab, KeyCode.grave]

    /// The default: hold ⌥ and press Tab, or ⌥⇧Tab to go backward.
    public static let `default` = Shortcut(validated: .option, keyCode: KeyCode.tab)
    /// The default same-app shortcut (SET-96): hold ⌥ and press `.
    public static let sameAppDefault = Shortcut(validated: .option, keyCode: KeyCode.grave)

    /// A shortcut from the modifiers held with the key, as a press reports them. The modifiers must be exactly ⌥ or
    /// exactly ⌃: the checks run in the order of `Invalid`'s cases, so ⌘⇧Tab is refused for its ⌘.
    public init(holdModifier modifiers: ModifierMask, keyCode: UInt16) throws(Invalid) {
        let modifiers = modifiers.intersection(.all)
        if modifiers.contains(.command) { throw .command }
        let held = modifiers.intersection([.option, .control])
        if held.isEmpty { throw .noHoldModifier }
        if held == [.option, .control] { throw .bothHoldModifiers }
        if modifiers.contains(.shift) { throw .shift }
        guard Self.allowedKeys.contains(keyCode) else { throw .key(keyCode) }
        self.holdModifier = held
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

    /// The key's name: "Tab" or "`".
    public var keyName: String { keyCode == KeyCode.grave ? "`" : "Tab" }

    /// The shortcut as menus write it, such as "⌥Tab".
    public var displayName: String { modifierSymbol + keyName }
}

extension Shortcut: Codable {
    private enum CodingKeys: String, CodingKey {
        case holdModifier
        case keyCode
    }

    /// Stored as `{"holdModifier": "option" | "control", "keyCode": <virtual key code>}`. A value that is not an
    /// allowed shortcut does not decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modifier: ModifierMask = switch try container.decode(String.self, forKey: .holdModifier) {
        case "option": .option
        case "control": .control
        default: throw DecodingError.dataCorruptedError(
            forKey: .holdModifier, in: container, debugDescription: "unknown holding modifier"
        )
        }
        do {
            try self.init(holdModifier: modifier, keyCode: container.decode(UInt16.self, forKey: .keyCode))
        } catch let error as Invalid {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: container, debugDescription: error.reason)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(holdModifier == .control ? "control" : "option", forKey: .holdModifier)
        try container.encode(keyCode, forKey: .keyCode)
    }
}
