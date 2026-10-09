import Foundation

enum SharedStore {
    static let suiteName = "group.dev.subset.breaks"
    static let settingsKey = "break.settings"
    static let snapshotKey = "break.snapshot"
    static let recordsKey = "break.records"
    static let selectionKey = "break.family-selection"
    static let commandKey = "break.pending-command"
    static let activeBreakEndKey = "break.active-end"
    static let notificationCategory = "BREAK_REMINDER"

    /// iOS shares state with its extensions through the app group. The macOS app has no extensions and
    /// uses its own defaults, which avoids the macOS prompt for undeclared group containers.
    static var defaults: UserDefaults {
        #if os(macOS)
        .standard
        #else
        UserDefaults(suiteName: suiteName) ?? .standard
        #endif
    }
}

enum AppGroupAssets {
    static func url(for filename: String) -> URL? {
        baseDirectory()?.appendingPathComponent(filename)
    }

    @discardableResult
    static func save(_ data: Data, filename: String) throws -> URL {
        guard let directory = baseDirectory() else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func baseDirectory() -> URL? {
        #if !os(macOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.suiteName) {
            return group.appendingPathComponent("CustomAssets", isDirectory: true)
        }
        #endif
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("Breaks/CustomAssets", isDirectory: true)
    }
}

struct BreakRepository {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = SharedStore.defaults) {
        self.defaults = defaults
    }

    func loadSettings() -> BreakSettings {
        decode(BreakSettings.self, key: SharedStore.settingsKey) ?? BreakSettings()
    }

    func loadSnapshot(settings: BreakSettings, now: Date = .now) -> EngineSnapshot {
        decode(EngineSnapshot.self, key: SharedStore.snapshotKey)
            ?? EngineSnapshot(nextBreakAt: now.addingTimeInterval(settings.workInterval))
    }

    func loadRecords() -> [BreakRecord] {
        decode([BreakRecord].self, key: SharedStore.recordsKey) ?? []
    }

    func save(settings: BreakSettings, snapshot: EngineSnapshot, records: [BreakRecord]) {
        encode(settings, key: SharedStore.settingsKey)
        encode(snapshot, key: SharedStore.snapshotKey)
        encode(Array(records.suffix(BreakRecord.historyLimit)), key: SharedStore.recordsKey)
    }

    func setCommand(_ command: String) {
        defaults.set(command, forKey: SharedStore.commandKey)
    }

    func takeCommand() -> String? {
        let command = defaults.string(forKey: SharedStore.commandKey)
        defaults.removeObject(forKey: SharedStore.commandKey)
        return command
    }

    func clearCommand() {
        defaults.removeObject(forKey: SharedStore.commandKey)
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
