import AppKit
import Carbon.HIToolbox
import Foundation

/// The app-wide actions that can be bound to a global (system-wide) shortcut.
enum GlobalShortcutAction: String, CaseIterable, Identifiable, Codable {
    case captureArea
    case captureWindow
    case recordScreen
    case captureText
    case captureHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .recordScreen: "Record Screen"
        case .captureText: "Capture Text"
        case .captureHistory: "Capture History"
        }
    }

    /// Stable Carbon hot key identifier.
    var hotKeyID: UInt32 {
        switch self {
        case .captureArea: 1
        case .captureWindow: 2
        case .recordScreen: 3
        case .captureText: 4
        case .captureHistory: 5
        }
    }

    /// macOS 15 rejects hot keys whose only modifiers are Option or Option-Shift, so every
    /// default includes Control.
    var defaultShortcut: KeyShortcut {
        switch self {
        case .captureArea: KeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .option], key: "S")
        case .captureWindow: KeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .option, .shift], key: "S")
        case .recordScreen: KeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .option, .shift], key: "R")
        case .captureText: KeyShortcut(keyCode: UInt32(kVK_ANSI_O), modifiers: [.control, .option, .shift], key: "O")
        case .captureHistory: KeyShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: [.control, .option, .shift], key: "H")
        }
    }
}

/// A key plus modifiers. `key` is the label recorded with the current keyboard layout.
struct KeyShortcut: Codable, Hashable {
    let keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, limited to ⌃ ⌥ ⇧ ⌘.
    let modifierFlags: UInt
    let key: String

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        modifierFlags = modifiers.intersection(Self.relevantModifiers).rawValue
        self.key = key
    }

    /// Builds a shortcut from a key-down event; nil for events without a usable key.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let keyCode = UInt32(event.keyCode)
        // The unmodified character, so ⇧/ is labelled "/" rather than "?".
        let typed = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
        let label = Self.specialKeyLabels[keyCode]
            ?? typed.map { Self.uppercasedLabel($0.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))) }
        guard let label, !label.isEmpty else { return nil }
        self.init(keyCode: keyCode, modifiers: event.modifierFlags, key: label)
    }

    /// Upper case for display, unless that changes the character count (ß becomes SS), which
    /// would leave the key without a menu key equivalent.
    static func uppercasedLabel(_ typed: String) -> String {
        let upper = typed.uppercased()
        return upper.count == typed.count ? upper : typed
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    var carbonModifiers: UInt32 {
        var result = 0
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        if modifiers.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }

    var displayString: String { Self.symbols(for: modifiers) + key }

    /// A global shortcut needs ⌃, or ⌘ together with ⌥ or ⇧. Plain ⌘ shortcuts would take
    /// over standard app commands such as ⌘C in every app, and macOS 15 rejects hot keys
    /// whose only modifiers are ⌥ or ⌥⇧.
    var isAllowedAsGlobalShortcut: Bool {
        modifiers.contains(.control)
            || (modifiers.contains(.command) && !modifiers.isDisjoint(with: [.option, .shift]))
    }

    /// The macOS screenshot shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5, with or without ⌃) keep priority over
    /// app hot keys while they are enabled in System Settings.
    var overlapsSystemScreenshotShortcut: Bool {
        let base = modifiers.subtracting(.control)
        return base == [.command, .shift]
            && [UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5)].contains(keyCode)
    }

    /// The menu item key equivalent, when the key has one.
    var menuKeyEquivalent: String? {
        if let special = Self.specialMenuKeys[keyCode] { return special }
        guard Self.specialKeyLabels[keyCode] == nil, key.count == 1 else { return nil }
        return key.lowercased()
    }

    static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    private static let specialKeyLabels: [UInt32: String] = {
        var labels: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() { labels[code] = "F\(index + 1)" }
        return Dictionary(uniqueKeysWithValues: labels.map { (UInt32($0.key), $0.value) })
    }()

    private static let specialMenuKeys: [UInt32: String] = {
        func character(_ value: Int) -> String { String(Character(UnicodeScalar(UInt16(value))!)) }
        var keys: [Int: String] = [
            kVK_Space: " ", kVK_Return: "\r", kVK_ANSI_KeypadEnter: character(NSEnterCharacter), kVK_Tab: "\t",
            kVK_Escape: "\u{1B}",
            kVK_Delete: character(NSBackspaceCharacter), kVK_ForwardDelete: character(NSDeleteFunctionKey),
            kVK_LeftArrow: character(NSLeftArrowFunctionKey), kVK_RightArrow: character(NSRightArrowFunctionKey),
            kVK_UpArrow: character(NSUpArrowFunctionKey), kVK_DownArrow: character(NSDownArrowFunctionKey),
            kVK_Home: character(NSHomeFunctionKey), kVK_End: character(NSEndFunctionKey),
            kVK_PageUp: character(NSPageUpFunctionKey), kVK_PageDown: character(NSPageDownFunctionKey),
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() { keys[code] = character(NSF1FunctionKey + index) }
        return Dictionary(uniqueKeysWithValues: keys.map { (UInt32($0.key), $0.value) })
    }()
}

/// The user's global shortcut choices: overrides of the defaults plus actions turned off.
struct GlobalShortcutBindings: Codable, Equatable {
    var overrides: [GlobalShortcutAction: KeyShortcut] = [:] { didSet { dropChangedStoredOverrides() } }
    var cleared: Set<GlobalShortcutAction> = []
    /// Stored data this version doesn't use (a newer version may have saved it): entries for
    /// unknown actions, cleared entries that aren't known action names and other top-level
    /// fields. They are written back as read, so editing a shortcut here doesn't erase them.
    private var unknownOverrides: [String: StoredJSON] = [:]
    private var unknownCleared: [StoredJSON] = []
    private var unknownFields: [String: StoredJSON] = [:]
    /// Each known override as stored, written back while the action keeps that shortcut so
    /// fields this version doesn't use survive.
    private var storedOverrides: [GlobalShortcutAction: StoredOverride] = [:]

    /// True when every action this version knows uses its default keys.
    var isAllDefault: Bool { cleared.isEmpty && GlobalShortcutAction.allCases.allSatisfy(isDefault) }

    func shortcut(for action: GlobalShortcutAction) -> KeyShortcut? {
        if cleared.contains(action) { return nil }
        return overrides[action] ?? action.defaultShortcut
    }

    /// True when the action uses its default keys. A default recorded on another keyboard
    /// layout keeps that layout's label but still counts as the default.
    func isDefault(_ action: GlobalShortcutAction) -> Bool {
        guard !cleared.contains(action) else { return false }
        return overrides[action].map(Self.sameKeys(action.defaultShortcut)) ?? true
    }

    /// The other action already using `shortcut`, if any.
    func action(using shortcut: KeyShortcut, except excluded: GlobalShortcutAction? = nil) -> GlobalShortcutAction? {
        GlobalShortcutAction.allCases.first { action in
            action != excluded && self.shortcut(for: action).map(Self.sameKeys(shortcut)) == true
        }
    }

    mutating func set(_ shortcut: KeyShortcut, for action: GlobalShortcutAction) {
        cleared.remove(action)
        overrides[action] = shortcut == action.defaultShortcut ? nil : shortcut
    }

    mutating func clear(_ action: GlobalShortcutAction) {
        overrides[action] = nil
        cleared.insert(action)
    }

    /// Restores every known action's default shortcut.
    mutating func resetAll() {
        overrides = [:]
        cleared = []
    }

    /// The action that would collide with `action` if it were reset to its default.
    func resetConflict(for action: GlobalShortcutAction) -> GlobalShortcutAction? {
        self.action(using: action.defaultShortcut, except: action)
    }

    /// Restores the default unless another action now uses it; returns that action instead of
    /// creating a duplicate binding (only one of two identical hot keys can register).
    @discardableResult
    mutating func reset(_ action: GlobalShortcutAction) -> GlobalShortcutAction? {
        if let conflict = resetConflict(for: action) { return conflict }
        overrides[action] = nil
        cleared.remove(action)
        return nil
    }

    /// Two shortcuts collide when they use the same physical key and modifiers, whatever label
    /// the keyboard layout produced.
    private static func sameKeys(_ lhs: KeyShortcut) -> (KeyShortcut) -> Bool {
        { rhs in lhs.keyCode == rhs.keyCode && lhs.modifierFlags == rhs.modifierFlags }
    }

    init(overrides: [GlobalShortcutAction: KeyShortcut] = [:], cleared: Set<GlobalShortcutAction> = []) {
        self.overrides = overrides
        self.cleared = cleared
    }

    /// Decodes each entry on its own: an unreadable entry, or a stored shortcut that a global
    /// shortcut may not use or that has modifiers beyond ⌃ ⌥ ⇧ ⌘ (hot key registration would
    /// drop them), falls back to that action's default without touching the others.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StoredKey.self)
        for key in container.allKeys where key != .overrides && key != .cleared {
            unknownFields[key.stringValue] = try? container.decode(StoredJSON.self, forKey: key)
        }
        if let rawOverrides = try? container.nestedContainer(keyedBy: StoredKey.self, forKey: .overrides) {
            for key in rawOverrides.allKeys {
                guard let action = GlobalShortcutAction(rawValue: key.stringValue) else {
                    unknownOverrides[key.stringValue] = try? rawOverrides.decode(StoredJSON.self, forKey: key)
                    continue
                }
                guard let shortcut = try? rawOverrides.decode(KeyShortcut.self, forKey: key),
                      shortcut.isAllowedAsGlobalShortcut,
                      shortcut.modifiers.isSubset(of: KeyShortcut.relevantModifiers) else { continue }
                overrides[action] = shortcut
                if let raw = try? rawOverrides.decode(StoredJSON.self, forKey: key) {
                    storedOverrides[action] = StoredOverride(shortcut: shortcut, raw: raw)
                }
            }
        }
        if var rawCleared = try? container.nestedUnkeyedContainer(forKey: .cleared) {
            while !rawCleared.isAtEnd, let entry = try? rawCleared.decode(StoredJSON.self) {
                if case let .string(name) = entry, let action = GlobalShortcutAction(rawValue: name) {
                    cleared.insert(action)
                    overrides[action] = nil
                } else {
                    unknownCleared.append(entry)
                }
            }
        }
        // An action that fell back to its default must not take keys another action now
        // uses (only one of two identical hot keys registers); leave it without a shortcut.
        for action in GlobalShortcutAction.allCases where overrides[action] == nil && !cleared.contains(action) {
            let collides = overrides.contains { other, shortcut in
                other != action && Self.sameKeys(shortcut)(action.defaultShortcut)
            }
            if collides { cleared.insert(action) }
        }
        dropChangedStoredOverrides()
    }

    private mutating func dropChangedStoredOverrides() {
        storedOverrides = storedOverrides.filter { overrides[$0.key] == $0.value.shortcut }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StoredKey.self)
        for (key, value) in unknownFields { try container.encode(value, forKey: StoredKey(key)) }
        var stored = unknownOverrides
        for (action, shortcut) in overrides {
            if let original = storedOverrides[action], original.shortcut == shortcut {
                stored[action.rawValue] = original.raw
            } else {
                stored[action.rawValue] = try StoredJSON(encoding: shortcut)
            }
        }
        try container.encode(stored, forKey: .overrides)
        // Names stay sorted as before; stored entries that aren't names follow unchanged.
        let names = cleared.map(\.rawValue) + unknownCleared.compactMap {
            if case let .string(name) = $0 { name } else { nil }
        }
        let others = unknownCleared.filter { if case .string = $0 { false } else { true } }
        try container.encode(names.sorted().map(StoredJSON.string) + others, forKey: .cleared)
    }

    private struct StoredOverride: Equatable {
        let shortcut: KeyShortcut
        let raw: StoredJSON
    }

    /// Any JSON key, so fields this version doesn't know can be read and written back.
    private struct StoredKey: CodingKey, Equatable {
        static let overrides = StoredKey("overrides")
        static let cleared = StoredKey("cleared")
        let stringValue: String
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.init(stringValue) }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// A JSON value kept as read, so it can be written back without losing anything.
    private indirect enum StoredJSON: Codable, Equatable {
        case null, bool(Bool), integer(Int64), unsigned(UInt64), number(Double), string(String)
        case array([StoredJSON]), object([String: StoredJSON])

        init(encoding value: some Encodable) throws {
            self = try JSONDecoder().decode(StoredJSON.self, from: JSONEncoder().encode(value))
        }

        init(from decoder: Decoder) throws {
            if let object = try? decoder.container(keyedBy: StoredKey.self) {
                self = .object(try Dictionary(uniqueKeysWithValues: object.allKeys.map {
                    ($0.stringValue, try object.decode(StoredJSON.self, forKey: $0))
                }))
            } else if var array = try? decoder.unkeyedContainer() {
                var values: [StoredJSON] = []
                while !array.isAtEnd { values.append(try array.decode(StoredJSON.self)) }
                self = .array(values)
            } else {
                let value = try decoder.singleValueContainer()
                if value.decodeNil() { self = .null }
                else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
                else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
                else if let unsigned = try? value.decode(UInt64.self) { self = .unsigned(unsigned) }
                else if let number = try? value.decode(Double.self) { self = .number(number) }
                else { self = .string(try value.decode(String.self)) }
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case let .object(object):
                var container = encoder.container(keyedBy: StoredKey.self)
                for (key, value) in object { try container.encode(value, forKey: StoredKey(key)) }
            case let .array(values):
                var container = encoder.unkeyedContainer()
                for value in values { try container.encode(value) }
            default:
                var container = encoder.singleValueContainer()
                switch self {
                case .null: try container.encodeNil()
                case let .bool(value): try container.encode(value)
                case let .integer(value): try container.encode(value)
                case let .unsigned(value): try container.encode(value)
                case let .number(value): try container.encode(value)
                case let .string(value): try container.encode(value)
                case .array, .object: break
                }
            }
        }
    }
}

struct ShortcutRegistration {
    let id: UInt32
    let name: String
    let keyCode: UInt32
    let modifiers: UInt32
    let handler: () -> Void
}

final class GlobalShortcutMonitor {
    static let shared = GlobalShortcutMonitor()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    /// Changes whenever the registrations change, so a hot-key press queued before a rebind
    /// doesn't run the action now bound to that ID.
    private var generation = 0

    /// Registers the shortcuts, replacing any registered earlier, and returns the IDs of any
    /// that could not be registered.
    @discardableResult
    func start(_ registrations: [ShortcutRegistration]) -> [UInt32] {
        stop()
        guard !registrations.isEmpty else { return [] }
        let eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard result == noErr else { return result }
                let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
                // Hot-key events arrive on the main thread; the action runs on the next turn.
                let generation = monitor.generation
                DispatchQueue.main.async {
                    guard monitor.generation == generation else { return }
                    monitor.handlers[identifier.id]?()
                }
                return noErr
            },
            1,
            [eventSpec],
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { return registrations.map(\.id) }
        var failed: [UInt32] = []

        for registration in registrations {
            var ref: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: OSType(0x53535043), id: registration.id)
            let result = RegisterEventHotKey(
                registration.keyCode,
                registration.modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if result == noErr, let ref {
                hotKeyRefs.append(ref)
                handlers[registration.id] = registration.handler
            } else {
                failed.append(registration.id)
            }
        }
        return failed
    }

    func stop() {
        hotKeyRefs.forEach { _ = UnregisterEventHotKey($0) }
        hotKeyRefs = []
        handlers = [:]
        generation &+= 1
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}
