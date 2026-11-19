import Darwin
import Foundation
@testable import SubsetCore
import XCTest

/// Cancels the task the caller runs in, as Cancel or the app quitting would at that moment.
func cancelCurrentTask() {
    withUnsafeCurrentTask { $0?.cancel() }
}

/// Writes an app bundle at `bundle` with an Info.plist of these values (nil leaves a key out).
func makeBundle(_ bundle: URL, bundleID: String, version: String?, build: String? = "1", minimumMacOS: String? = nil) throws {
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": bundleID]
    if let version { info["CFBundleShortVersionString"] = version }
    if let build { info["CFBundleVersion"] = build }
    if let minimumMacOS { info["LSMinimumSystemVersion"] = minimumMacOS }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
}

/// A thread-safe box for what a fake records.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

/// Serves recorded bytes for each URL.
struct FakeDownloader: ImageDownloading {
    var images: [String: Data]
    var cancelDuring = false
    let calls = Recorder(0)

    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        calls.update { $0 += 1 }
        guard let data = images[url.absoluteString] else { throw InstallFailure(.download, "HTTP 404") }
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw InstallFailure(.download, "cannot write")
        }
        progress(Int64(data.count), Int64(data.count))
        if cancelDuring { cancelCurrentTask() }
    }
}

/// Mounts an image by making its volumes from `contents` (the image's SHA-256 picks which), and detaches by removing
/// them.
final class FakeImages: DiskImageAttaching, @unchecked Sendable {
    /// What each image holds: volume name to the files to make in it, by the image's bytes.
    var volumes: [Data: [String: (URL) throws -> Void]] = [:]
    var cancelDuring = false
    let attached = Recorder<[URL]>([])
    let detached = Recorder(0)

    func attach(_ image: URL, mountRoot: URL) async throws -> [String] {
        let bytes = try Data(contentsOf: image)
        guard let volumes = volumes[bytes] else { throw InstallFailure(.image, "hdiutil could not attach the image (not a disk image)") }
        for (name, make) in volumes {
            let volume = mountRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
            try make(volume)
            attached.update { $0.append(volume) }
        }
        if cancelDuring { cancelCurrentTask() }
        return ["/dev/disk99"]
    }

    func detach(_ image: URL, devices: [String]) async -> Bool {
        detached.update { $0 += 1 }
        for volume in attached.get() { try? FileManager.default.removeItem(at: volume) }
        attached.update { $0 = [] }
        return true
    }
}

/// Stands in for the Security framework and Gatekeeper: `refusal` is what they would say, then the real Info.plist
/// checks run on the staged copy.
struct FakeVerifier: AppVerifying {
    var refusal: InstallFailure?
    var runningMacOS = "14.5.0"
    var cancelDuring = false
    /// Runs while the staged copy is being verified (to change the destination meanwhile).
    var during: (@Sendable (URL) throws -> Void)?
    let verified = Recorder<[URL]>([])

    func verify(_ bundle: URL, expected: ExpectedApp) async throws {
        verified.update { $0.append(bundle) }
        try during?(bundle)
        if cancelDuring { cancelCurrentTask() }
        if let refusal { throw refusal }
        guard let info = InstalledAppFinder.infoPlist(bundle.path) else { throw InstallFailure(.bundleID, "its Contents/Info.plist cannot be read") }
        try SecurityAppVerifier.checkInfo(info, expected: expected, runningMacOS: runningMacOS)
    }
}

/// Running apps by bundle path; `quit` stops them unless `stubborn`.
final class FakeRunning: RunningAppControlling, @unchecked Sendable {
    let running = Recorder<Set<String>>([])
    let quits = Recorder<[String]>([])
    let reopened = Recorder<[String]>([])
    var stubborn = false
    /// The list of processes cannot be read (libproc failed).
    var unreadable = false
    /// Runs when an app is asked to quit (to check what has happened by then).
    var onQuit: (@Sendable () -> Void)?
    /// Cancel is pressed while the app is quitting.
    var cancelDuringQuit = false
    /// Bundles where only a helper (no app to ask to quit) runs.
    let helpers = Recorder<Set<String>>([])
    /// The helper exits between the first look and the quit (so a fresh look finds nothing).
    var helperExitsOnQuit = false

    func processes(inside bundle: URL) throws -> [pid_t] {
        if unreadable { throw InstallFailure(.running, "whether the app is running cannot be read (fake)") }
        return (running.get().contains(bundle.path) ? [4242] : []) + (helpers.get().contains(bundle.path) ? [4343] : [])
    }

    func quit(_ bundle: URL, timeout _: TimeInterval) async throws -> (left: [pid_t], asked: Bool) {
        let asked = running.get().contains(bundle.path)
        if helperExitsOnQuit { helpers.update { $0.remove(bundle.path) } }
        guard asked else { return (try processes(inside: bundle), false) }
        onQuit?()
        if cancelDuringQuit { cancelCurrentTask() }
        quits.update { $0.append(bundle.path) }
        if !stubborn { running.update { $0.remove(bundle.path) } }
        return (try processes(inside: bundle), true)
    }

    func reopen(_ bundle: URL) async -> String? {
        reopened.update { $0.append(bundle.path) }
        return nil
    }
}
