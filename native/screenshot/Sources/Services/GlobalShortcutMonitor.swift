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
            ?? typed?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).uppercased()
        guard let label, !label.isEmpty else { return nil }
        self.init(keyCode: keyCode, modifiers: event.modifierFlags, key: label)
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
            kVK_Space: " ", kVK_Return: "\r", kVK_Tab: "\t",
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
    var overrides: [GlobalShortcutAction: KeyShortcut] = [:]
    var cleared: Set<GlobalShortcutAction> = []

    func shortcut(for action: GlobalShortcutAction) -> KeyShortcut? {
        if cleared.contains(action) { return nil }
        return overrides[action] ?? action.defaultShortcut
    }

    func isDefault(_ action: GlobalShortcutAction) -> Bool {
        overrides[action] == nil && !cleared.contains(action)
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

    mutating func reset(_ action: GlobalShortcutAction) {
        overrides[action] = nil
        cleared.remove(action)
    }

    /// Two shortcuts collide when they use the same physical key and modifiers, whatever label
    /// the keyboard layout produced.
    private static func sameKeys(_ lhs: KeyShortcut) -> (KeyShortcut) -> Bool {
        { rhs in lhs.keyCode == rhs.keyCode && lhs.modifierFlags == rhs.modifierFlags }
    }

    // Encode with string keys so the stored JSON stays readable and forward compatible.
    private enum CodingKeys: String, CodingKey { case overrides, cleared }

    init(overrides: [GlobalShortcutAction: KeyShortcut] = [:], cleared: Set<GlobalShortcutAction> = []) {
        self.overrides = overrides
        self.cleared = cleared
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawOverrides = try container.decodeIfPresent([String: KeyShortcut].self, forKey: .overrides) ?? [:]
        overrides = Dictionary(uniqueKeysWithValues: rawOverrides.compactMap { key, value in
            GlobalShortcutAction(rawValue: key).map { ($0, value) }
        })
        let rawCleared = try container.decodeIfPresent([String].self, forKey: .cleared) ?? []
        cleared = Set(rawCleared.compactMap(GlobalShortcutAction.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }), forKey: .overrides)
        try container.encode(cleared.map(\.rawValue).sorted(), forKey: .cleared)
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
                DispatchQueue.main.async { monitor.handlers[identifier.id]?() }
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
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}
