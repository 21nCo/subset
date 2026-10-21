import Foundation

/// Which windows the switcher shows, beyond `WindowFilter`'s closed rules. Each option only removes from what those
/// rules list, except `windowlessApps`, which adds a cell for each app that has no switchable window.
public struct ShownWindows: Sendable, Equatable, Codable {
    /// Minimized windows. On by default.
    public var minimized = true
    /// Windows of hidden apps (⌘H), and the cells of hidden windowless apps. On by default.
    public var hiddenApps = true
    /// A cell for each regular app with no switchable window; committing it activates the app. Off by default.
    public var windowlessApps = false
    /// Only windows on the display under the pointer. Off by default.
    public var pointerDisplayOnly = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case minimized
        case hiddenApps
        case windowlessApps
        case pointerDisplayOnly
    }

    /// An absent option takes its default; a present one of the wrong type does not decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minimized = try container.decodeIfPresent(Bool.self, forKey: .minimized) ?? minimized
        hiddenApps = try container.decodeIfPresent(Bool.self, forKey: .hiddenApps) ?? hiddenApps
        windowlessApps = try container.decodeIfPresent(Bool.self, forKey: .windowlessApps) ?? windowlessApps
        pointerDisplayOnly = try container.decodeIfPresent(Bool.self, forKey: .pointerDisplayOnly) ?? pointerDisplayOnly
    }
}

/// Hop's settings, the only thing it persists. Stored as JSON in the app's user defaults under `defaultsKey`, with a
/// `schemaVersion` of 1.
///
/// Within version 1 an absent key takes its default, so later settings can be added without a new version. Anything
/// else that does not decode (data that is not JSON, another version, a value of the wrong type, a shortcut that is
/// not allowed, or a shortcut equal to the same-app shortcut) reads as `Settings.default`, and is overwritten by the
/// next change.
public struct Settings: Sendable, Equatable {
    public static let schemaVersion = 1
    public static let defaultsKey = "\(HopIdentity.bundleIdentifier).settings"
    public static let `default` = Settings()

    /// The hold-to-switch shortcut.
    public private(set) var shortcut: Shortcut = .default
    /// The same-app shortcut, which switches among the frontmost app's windows; the two shortcuts are never equal.
    public private(set) var sameAppShortcut: Shortcut = .sameAppDefault
    public var shownWindows = ShownWindows()
    /// The bundle IDs of apps whose windows never appear, in the order they were added, without duplicates.
    public private(set) var excludedApps: [String] = []

    public init() {}

    /// The shortcut in `role`.
    public func shortcut(for role: ShortcutRole) -> Shortcut {
        switch role {
        case .switchWindows: shortcut
        case .sameApp: sameAppShortcut
        }
    }

    /// Checks a shortcut pressed with `modifiers` and `keyCode` for use in `role`: the combination must be allowed
    /// (`Shortcut.init`) and must not be the other role's shortcut.
    public func validateShortcut(
        modifiers: ModifierMask,
        keyCode: UInt16,
        for role: ShortcutRole = .switchWindows
    ) throws(Shortcut.Invalid) -> Shortcut {
        let shortcut = try Shortcut(holdModifier: modifiers, keyCode: keyCode)
        try check(shortcut, for: role)
        return shortcut
    }

    private func check(_ shortcut: Shortcut, for role: ShortcutRole) throws(Shortcut.Invalid) {
        switch role {
        case .switchWindows where shortcut == sameAppShortcut: throw .sameAppShortcut(sameAppShortcut)
        case .sameApp where shortcut == self.shortcut: throw .switchShortcut(self.shortcut)
        case .switchWindows, .sameApp: break
        }
    }

    /// What the shortcut recorder makes of a key press for `role`: a new shortcut, a refusal with its reason, or Esc
    /// (with no modifier) to stop recording. Key-ups, modifier changes and auto-repeats are ignored.
    public func record(_ key: KeyEvent, for role: ShortcutRole = .switchWindows) -> ShortcutRecording {
        guard key.kind == .keyDown, !key.isRepeat else { return .ignored }
        if key.keyCode == KeyCode.escape, key.modifiers.isEmpty { return .cancelled }
        do {
            return try .recorded(validateShortcut(modifiers: key.modifiers, keyCode: key.keyCode, for: role))
        } catch {
            return .rejected(error)
        }
    }

    /// Sets the shortcut in `role`, unless it is the other role's shortcut.
    public mutating func setShortcut(_ shortcut: Shortcut, for role: ShortcutRole = .switchWindows) throws(Shortcut.Invalid) {
        try check(shortcut, for: role)
        switch role {
        case .switchWindows: self.shortcut = shortcut
        case .sameApp: sameAppShortcut = shortcut
        }
    }

    /// Back to the role's default (⌥Tab, or ⌥` for the same-app shortcut), unless that is the other role's shortcut;
    /// then the shortcut stays as it is.
    public mutating func resetShortcut(_ role: ShortcutRole = .switchWindows) throws(Shortcut.Invalid) {
        try setShortcut(role.defaultShortcut, for: role)
    }

    /// Adds an app to the excluded list, unless it is already there. An empty bundle ID is ignored.
    public mutating func exclude(_ bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty, !excludedApps.contains(bundleIdentifier) else { return }
        excludedApps.append(bundleIdentifier)
    }

    public mutating func include(_ bundleIdentifier: String) {
        excludedApps.removeAll { $0 == bundleIdentifier }
    }

    /// Whether an app's windows may be listed: false when its bundle ID is excluded. An app without a bundle ID
    /// cannot be excluded.
    public func allows(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        return !excludedApps.contains(bundleIdentifier)
    }
}

/// The two shortcuts a user sets: hold-to-switch over every window, and the same-app shortcut over the frontmost
/// app's windows. Both follow `Shortcut`'s rules, and they may not be equal.
public enum ShortcutRole: Sendable, Equatable, CaseIterable {
    case switchWindows
    case sameApp

    /// ⌥Tab, or ⌥` for the same-app shortcut.
    public var defaultShortcut: Shortcut {
        switch self {
        case .switchWindows: .default
        case .sameApp: .sameAppDefault
        }
    }
}

/// The outcome of one key press while the Settings window records a shortcut.
public enum ShortcutRecording: Sendable, Equatable {
    case recorded(Shortcut)
    case rejected(Shortcut.Invalid)
    /// Esc: stop recording and keep the shortcut.
    case cancelled
    /// Not a new key press; recording goes on.
    case ignored
}

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case shortcut
        case sameAppShortcut
        case shownWindows
        case excludedApps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container, debugDescription: "unknown schema version \(version)"
            )
        }
        sameAppShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .sameAppShortcut) ?? .sameAppDefault
        let shortcut = try container.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? .default
        do {
            try setShortcut(shortcut)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .shortcut, in: container, debugDescription: error.reason)
        }
        shownWindows = try container.decodeIfPresent(ShownWindows.self, forKey: .shownWindows) ?? ShownWindows()
        for bundleIdentifier in try container.decodeIfPresent([String].self, forKey: .excludedApps) ?? [] {
            exclude(bundleIdentifier)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(shortcut, forKey: .shortcut)
        try container.encode(sameAppShortcut, forKey: .sameAppShortcut)
        try container.encode(shownWindows, forKey: .shownWindows)
        try container.encode(excludedApps, forKey: .excludedApps)
    }
}

/// Reads and writes `Settings` in user defaults under `Settings.defaultsKey`.
public struct SettingsStore: @unchecked Sendable {
    // UserDefaults is thread-safe; it is not marked Sendable.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored settings, or the defaults when nothing is stored or what is stored does not decode. Reading never
    /// writes: unreadable data stays until the next `save`.
    public func load() -> Settings {
        guard let data = defaults.data(forKey: Settings.defaultsKey),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .default }
        return settings
    }

    public func save(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Settings holds only strings, booleans and integers, which always encode.
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: Settings.defaultsKey)
    }
}
