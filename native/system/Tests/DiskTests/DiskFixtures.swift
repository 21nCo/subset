import Darwin
import Foundation
import SystemCore
import SystemDisk
import SystemProcesses
import XCTest

/// A fixture home folder on the runner's volume, scanned with the real `DiskScanner` and analyzed with an injected app
/// list, so the Disk model's tabs come from a real tree.
@MainActor
final class DiskFixture {
    nonisolated static let editor = InstalledApp(
        path: "/Applications/Editor.app", bundleID: "com.example.editor", name: "Editor",
        signature: CodeSignature(signingID: "com.example.editor", teamID: "EXAMPLE123", isPlatformBinary: false,
                                 teamName: "Example Ltd"))
    nonisolated static let volume = VolumeSummary(
        values: VolumeCapacityValues(mountPoint: "/", name: "Macintosh HD", capacity: 500_000_000_000,
                                     availableForImportantUsage: 120_000_000_000, available: 100_000_000_000),
        snapshots: .count(2))

    let home: String
    private var locked: [String] = []

    init() throws {
        let base = NSTemporaryDirectory() + "DiskWindowModelTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: false)
        let real = try XCTUnwrap(realpath(base, nil))
        defer { free(real) }
        home = String(cString: real)
    }

    /// A home folder with documents, an installed app's cache, Homebrew's cache, Xcode's DerivedData, a leftover's
    /// preferences, and the Trash.
    func populate() throws {
        try write("Documents/big.bin", bytes: 1_000_000)
        try write("Documents/Sub/notes.bin", bytes: 60_000)
        try write("Documents/small.bin", bytes: 8_000)
        try write("Library/Caches/com.example.editor/cache.db", bytes: 300_000)
        try write("Library/Caches/Homebrew/bottle.tar.gz", bytes: 200_000)
        try write("Library/Developer/Xcode/DerivedData/App-abc/Build/app", bytes: 500_000)
        try write("Library/Preferences/com.gone.app.plist", bytes: 4_000)
        try write(".Trash/old.zip", bytes: 100_000)
    }

    /// A folder the scan cannot read.
    func lock(_ relative: String) throws {
        try write(relative + "/secret.bin", bytes: 4_000)
        let path = path(relative)
        XCTAssertEqual(chmod(path, 0), 0)
        locked.append(path)
    }

    func remove() {
        for path in locked { chmod(path, 0o755) }
        try? FileManager.default.removeItem(atPath: home)
    }

    func path(_ relative: String) -> String { home + "/" + relative }

    func write(_ relative: String, bytes: Int) throws {
        let url = URL(fileURLWithPath: path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random bytes, so APFS cannot compress them.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: url)
    }

    var format: UsageFormat { UsageFormat(locale: Locale(identifier: "en_US_POSIX"), home: home) }

    /// Analyzes with the fixture's apps and no simulator runtimes; Docker is never asked.
    nonisolated static func analysis(_ result: DiskScanResult, home: String) -> DiskAnalysis {
        DiskAnalysis(tree: result.tree, context: ReclaimContext(home: home, installedApps: InstalledApps([editor]),
                                                                simulatorRuntimes: .installed([])))
    }

    /// The real scanner, the fixture's analysis, and the fixture volume.
    func service(scan: (@Sendable (String, @escaping @Sendable (DiskScanProgress) -> Void) async -> Result<DiskScanResult, DiskScanError>)? = nil,
                 analyze: (@Sendable (DiskScanResult, Bool) async -> DiskAnalysis)? = nil) -> DiskScanService {
        let home = home
        return DiskScanService(
            scan: scan ?? { root, onProgress in
                await DiskScanService.scan(DiskScanner(workers: 2), root: root, onProgress: onProgress)
            },
            analyze: analyze ?? { result, _ in Self.analysis(result, home: home) },
            volume: { _ in Self.volume })
    }

    func model(rowLimit: Int = 500, service: DiskScanService? = nil) -> DiskWindowModel {
        DiskWindowModel(service: service ?? self.service(), format: format, home: home, rowLimit: rowLimit)
    }

    /// Scans the home scope and waits for origins and suggestions.
    func scanned(rowLimit: Int = 500) async throws -> DiskWindowModel {
        let model = model(rowLimit: rowLimit)
        model.scan()
        try await Self.wait { !model.isScanning }
        XCTAssertEqual(model.phase, .completed)
        return model
    }

    static func wait(timeout: TimeInterval = 30, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

struct TimedOut: Error {}

/// A one-shot gate a scan thread blocks on until the test opens it.
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var passed = false
    /// Fulfilled when a thread first reaches the gate.
    let reached = XCTestExpectation(description: "reached the gate")

    /// Blocks the first caller until `open`; later callers pass.
    func pass() {
        let first = lock.withLock {
            defer { passed = true }
            return !passed
        }
        guard first else { return }
        reached.fulfill()
        semaphore.wait()
    }

    func open() { semaphore.signal() }
}

extension DiskWindowModel {
    var rows: [DiskRow] { sections.flatMap(\.rows) }

    func row(named name: String) -> DiskRow? { rows.first { $0.name == name } }

    func section(_ id: String) -> DiskRowSection? { sections.first { $0.id == id } }
}
