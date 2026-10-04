import Darwin
import Foundation

public enum RecordingMode: String, Codable, Sendable {
    case off
    case recording
    case paused
}

public struct RecordingSettings: Codable, Sendable {
    public var mode: RecordingMode = .off
    public var allowedApps: [String: String] = [:]

    public init() {}
}

public enum RecordingError: Error, LocalizedError, Equatable {
    case invalidBundleIdentifier
    case damagedSettings
    case damagedArchive
    case recorderInUse

    public var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier: "The foreground app has no valid bundle identifier."
        case .damagedSettings: "Recording settings could not be read. Recording is disabled until the file is repaired."
        case .damagedArchive: "Captured data could not be read. It was not overwritten."
        case .recorderInUse: "Another M Graph instance already owns foreground recording."
        }
    }
}

// The native host is the only writer. A private directory and atomic replacement
// keep an interrupted write from creating a partially granted allowlist.
@MainActor public final class RecordingVault {
    private let settingsURL: URL
    private let archiveURL: URL
    private let lockFD: Int32
    public private(set) var settings: RecordingSettings
    public private(set) var observations: [CaptureResult]
    public static let maximumObservations = 50

    private static func acquireLock(in directory: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lockURL = directory.appendingPathComponent("recording.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecordingError.recorderInUse }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw RecordingError.recorderInUse
        }
        return fd
    }

    public init(directory: URL) throws {
        let fd = try Self.acquireLock(in: directory)
        lockFD = fd
        var initialized = false
        defer { if !initialized { Darwin.close(fd) } }
        settingsURL = directory.appendingPathComponent("recording-settings.json")
        archiveURL = directory.appendingPathComponent("captured-observations.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard Self.isRegularFile(settingsURL, maximumBytes: 32_768),
                  let data = try? Data(contentsOf: settingsURL),
                  let decoded = try? JSONDecoder().decode(RecordingSettings.self, from: data),
                  decoded.allowedApps.allSatisfy({ Self.validBundleIdentifier($0.key) &&
                      Self.validBundlePath($0.value) }) else {
                throw RecordingError.damagedSettings
            }
            // A new process never resumes recording without a fresh local Start.
            settings = decoded
            settings.mode = .off
        } else {
            settings = RecordingSettings()
        }
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard Self.isRegularFile(archiveURL, maximumBytes: 4_000_000),
                  let data = try? Data(contentsOf: archiveURL),
                  let decoded = try? decoder.decode([CaptureResult].self, from: data),
                  decoded.count <= Self.maximumObservations,
                  decoded.allSatisfy({ result in
                      result.state == .available &&
                      result.text.map { !$0.isEmpty && $0.count <= 6000 } == true &&
                      result.bundleIdentifier.map(Self.validBundleIdentifier) == true
                  }) else {
                throw RecordingError.damagedArchive
            }
            observations = decoded
        } else {
            observations = []
        }
        initialized = true
    }

    deinit { Darwin.close(lockFD) }

    // Allows recovery from a damaged archive without bypassing the live writer's lock.
    // The owner must be closed before this can erase data it might still hold in memory.
    public static func eraseArchiveWhileClosed(in directory: URL) throws {
        let fd = try acquireLock(in: directory)
        defer { Darwin.close(fd) }
        let archive = directory.appendingPathComponent("captured-observations.json")
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
    }

    public var retainedAppIdentifiers: [String] {
        Array(Set(observations.compactMap(\.bundleIdentifier))).sorted()
    }

    public static func validBundleIdentifier(_ identifier: String) -> Bool {
        identifier.count <= 255 && identifier.range(
            of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    }

    private static func validBundlePath(_ path: String) -> Bool {
        path.hasPrefix("/") && URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
    }

    private static func canonicalBundlePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isRegularFile(_ url: URL, maximumBytes: Int) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue <= maximumBytes
    }

    public func allows(_ bundleIdentifier: String?, at bundleURL: URL?) -> Bool {
        guard settings.mode == .recording, let bundleIdentifier, let bundleURL,
              let selectedPath = settings.allowedApps[bundleIdentifier] else { return false }
        return selectedPath == Self.canonicalBundlePath(bundleURL)
    }

    public func setMode(_ mode: RecordingMode) throws {
        var next = settings
        next.mode = mode
        if mode != .recording { settings.mode = mode }
        try save(next, to: settingsURL)
        settings = next
    }

    public func allow(_ bundleIdentifier: String, at bundleURL: URL) throws {
        let path = Self.canonicalBundlePath(bundleURL)
        guard Self.validBundleIdentifier(bundleIdentifier), Self.validBundlePath(path) else {
            throw RecordingError.invalidBundleIdentifier
        }
        var next = settings
        next.allowedApps[bundleIdentifier] = path
        try save(next, to: settingsURL)
        settings = next
    }

    public func exclude(_ bundleIdentifier: String) throws {
        var next = settings
        next.allowedApps.removeValue(forKey: bundleIdentifier)
        settings.allowedApps.removeValue(forKey: bundleIdentifier)
        try save(next, to: settingsURL)
        settings = next
    }

    public func append(_ result: CaptureResult, from bundleURL: URL) throws {
        guard result.state == .available, let text = result.text,
              !text.isEmpty, text.count <= 6000,
              allows(result.bundleIdentifier, at: bundleURL) else { return }
        if let previous = observations.last,
           previous.bundleIdentifier == result.bundleIdentifier,
           previous.windowTitle == result.windowTitle,
           previous.documentURL == result.documentURL,
           previous.text == result.text { return }
        var next = observations
        next.append(result)
        if next.count > Self.maximumObservations {
            next.removeFirst(next.count - Self.maximumObservations)
        }
        try save(next, to: archiveURL)
        observations = next
    }

    public func deleteCapturedData(bundleIdentifier: String? = nil) throws {
        // Deletion must not be undone by the next scheduled foreground read.
        try setMode(.paused)
        if let bundleIdentifier {
            let next = observations.filter { $0.bundleIdentifier != bundleIdentifier }
            if next.isEmpty {
                try removeArchive()
            } else {
                try save(next, to: archiveURL)
            }
            observations = next
        } else {
            try removeArchive()
            observations = []
        }
    }

    private func removeArchive() throws {
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// Notifications, polling, and late worker completions share one monotonic gate.
// Invalidating it fences a result after pause, exclusion, deletion, switch, or sleep.
@MainActor public final class RecordingGate {
    public static let minimumInterval: TimeInterval = 3
    private var generation: UInt64 = 0
    private var inFlight = false
    private var nextAllowed: TimeInterval = 0

    public init() {}

    public func canBegin(at uptime: TimeInterval) -> Bool {
        !inFlight && uptime >= nextAllowed
    }

    public func begin(at uptime: TimeInterval) -> UInt64? {
        guard canBegin(at: uptime) else { return nil }
        inFlight = true
        nextAllowed = uptime + Self.minimumInterval
        return generation
    }

    public func finish(_ token: UInt64) -> Bool {
        guard generation == token, inFlight else { return false }
        inFlight = false
        return true
    }

    public func invalidate() {
        generation &+= 1
        inFlight = false
        nextAllowed = 0
    }
}
