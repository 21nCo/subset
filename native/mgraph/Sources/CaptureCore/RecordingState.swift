import Darwin
import Foundation

/// Local automatic capture state; a new process always resumes in `off`.
public enum RecordingMode: String, Codable, Sendable {
    case off
    case recording
    case paused
}

/// Private on-disk policy: an empty allowlist denies every application.
public struct RecordingSettings: Codable, Sendable {
    public var mode: RecordingMode = .off
    public var allowedApps: [String: String] = [:]

    public init() {}
}

/// Errors surfaced by the native recording controls and archive loader.
public enum RecordingError: Error, LocalizedError, Equatable {
    case invalidBundleIdentifier(String)
    case damagedSettings
    case damagedArchive
    case archiveTooLarge
    case recorderInUse

    public var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier(let name): "The selected app \"\(name)\" has no valid bundle identifier."
        case .damagedSettings: "Recording settings could not be read. Recording is disabled until the file is repaired."
        case .damagedArchive: "Captured data could not be read. It was not overwritten."
        case .archiveTooLarge: "Captured data exceeds the private archive limit. Recording is paused."
        case .recorderInUse: "Another M Graph instance already owns foreground recording."
        }
    }
}

/// Owns the single-writer allowlist and bounded private observation archive.
/// File replacement is the commit point; no fallible work follows it.
@MainActor public final class RecordingVault {
    private let settingsURL: URL
    private let archiveURL: URL
    private let lockFD: Int32
    public private(set) var settings: RecordingSettings
    public private(set) var observations: [CaptureResult]
    public static let maximumObservations = 50
    public static let maximumArchiveBytes = 4_000_000
    enum StorageCheckpoint: Equatable { case beforeCommit, afterCommit }
    // Test seam: post-commit diagnostics must never turn a committed write into a failure.
    var storageCheckpoint: ((StorageCheckpoint) throws -> Void)?

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
        do { try removeInterruptedWrites(in: directory) }
        catch { Darwin.close(fd); throw error }
        return fd
    }

    private static func removeInterruptedWrites(in directory: URL) throws {
        let staged = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in staged where url.lastPathComponent.hasSuffix(".tmp") &&
            (url.lastPathComponent.hasPrefix(".recording-settings.json.") ||
             url.lastPathComponent.hasPrefix(".captured-observations.json.")) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Opens a locked vault, validating existing files and starting in Off mode.
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
            guard Self.isRegularFile(archiveURL, maximumBytes: Self.maximumArchiveBytes),
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

    /// Erases a damaged archive only when no live recorder owns its directory.
    /// The owner must be closed first so it cannot restore deleted observations.
    public static func eraseArchiveWhileClosed(in directory: URL) throws {
        let fd = try acquireLock(in: directory)
        defer { Darwin.close(fd) }
        let archive = directory.appendingPathComponent("captured-observations.json")
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
    }

    /// Bundle identifiers with retained observations, including apps now excluded.
    public var retainedAppIdentifiers: [String] {
        Array(Set(observations.compactMap(\.bundleIdentifier))).sorted()
    }

    /// Accepts a dotted CFBundleIdentifier using Apple's ASCII component characters.
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

    /// Requires recording mode and an exact canonical bundle path match.
    public func allows(_ bundleIdentifier: String?, at bundleURL: URL?) -> Bool {
        guard settings.mode == .recording, let bundleIdentifier, let bundleURL,
              let selectedPath = settings.allowedApps[bundleIdentifier] else { return false }
        return selectedPath == Self.canonicalBundlePath(bundleURL)
    }

    /// Persists the selected mode; a failed stop or pause still disables live reads.
    public func setMode(_ mode: RecordingMode) throws {
        var next = settings
        next.mode = mode
        if mode != .recording { settings.mode = mode }
        do { try save(next, to: settingsURL) }
        catch { pauseLiveRecording(); throw error }
        settings = next
    }

    /// Adds a selected bundle identifier and canonical app path; it never starts recording.
    public func allow(_ bundleIdentifier: String, at bundleURL: URL) throws {
        let path = Self.canonicalBundlePath(bundleURL)
        guard Self.validBundleIdentifier(bundleIdentifier), Self.validBundlePath(path) else {
            throw RecordingError.invalidBundleIdentifier(bundleURL.lastPathComponent)
        }
        var next = settings
        next.allowedApps[bundleIdentifier] = path
        do { try save(next, to: settingsURL) }
        catch { pauseLiveRecording(); throw error }
        settings = next
    }

    /// Removes a selected bundle after its new settings file commits.
    public func exclude(_ bundleIdentifier: String) throws {
        var next = settings
        next.allowedApps.removeValue(forKey: bundleIdentifier)
        do { try save(next, to: settingsURL) }
        catch { pauseLiveRecording(); throw error }
        settings = next
    }

    /// Retains a permitted, bounded result only when its encoded archive can reopen.
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
        do { try save(next, to: archiveURL, maximumBytes: Self.maximumArchiveBytes) }
        catch { pauseLiveRecording(); throw error }
        observations = next
    }

    /// Pauses active capture before removing one app's data or all retained text.
    public func deleteCapturedData(bundleIdentifier: String? = nil) throws {
        // Fence active recording before erasure without changing a selected Off or Paused mode.
        if settings.mode == .recording { try setMode(.paused) }
        if let bundleIdentifier {
            let next = observations.filter { $0.bundleIdentifier != bundleIdentifier }
            do {
                if next.isEmpty { try removeArchive() }
                else { try save(next, to: archiveURL, maximumBytes: Self.maximumArchiveBytes) }
            } catch { pauseLiveRecording(); throw error }
            observations = next
        } else {
            do { try removeArchive() }
            catch { pauseLiveRecording(); throw error }
            observations = []
        }
    }

    private func pauseLiveRecording() {
        if settings.mode == .recording { settings.mode = .paused }
    }

    private func removeArchive() throws {
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try storageCheckpoint?(.beforeCommit)
            guard Darwin.unlink(archiveURL.path) == 0 else { throw Self.posixError() }
            // The unlink is the commit point; diagnostic failures cannot restore text.
            try? storageCheckpoint?(.afterCommit)
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func save<T: Encodable>(_ value: T, to url: URL, maximumBytes: Int? = nil) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        if let maximumBytes, data.count > maximumBytes { throw RecordingError.archiveTooLarge }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        defer { _ = Darwin.unlink(temporary.path) }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Self.posixError() }
                offset += written
            }
        }
        guard Darwin.fsync(fd) == 0 else { throw Self.posixError() }
        try storageCheckpoint?(.beforeCommit)
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw Self.posixError() }
        // All fallible preparation, including the 0600 mode, preceded rename.
        try? storageCheckpoint?(.afterCommit)
    }
}

/// Shares one monotonic throttle across notifications, polling, and worker completions.
/// Invalidation fences a result without resetting the process-wide attempt interval.
@MainActor public final class RecordingGate {
    public static let minimumInterval: TimeInterval = 3
    private var generation: UInt64 = 0
    private var inFlight = false
    private var nextAllowed: TimeInterval = 0

    /// Starts a gate with no in-flight read or throttle delay.
    public init() {}

    /// Reports whether another automatic AX request may begin at the given uptime.
    public func canBegin(at uptime: TimeInterval) -> Bool {
        !inFlight && uptime >= nextAllowed
    }

    /// Reserves an attempt and returns the generation used to fence late results.
    public func begin(at uptime: TimeInterval) -> UInt64? {
        guard canBegin(at: uptime) else { return nil }
        inFlight = true
        nextAllowed = uptime + Self.minimumInterval
        return generation
    }

    /// Extends the throttle from actual AX worker admission after queue contention.
    /// The bound survives a later foreground or recording-control invalidation.
    public func recordCaptureStart(at uptime: TimeInterval) {
        nextAllowed = max(nextAllowed, uptime + Self.minimumInterval)
    }

    /// Accepts a completion only while its generation is still live.
    public func finish(_ token: UInt64) -> Bool {
        guard generation == token, inFlight else { return false }
        inFlight = false
        return true
    }

    /// Discards pending work while retaining the automatic capture interval.
    public func invalidate() {
        generation &+= 1
        inFlight = false
    }
}
