import Darwin
import Foundation
@testable import SystemCore
import SystemHelper
import XCTest

/// A recorded process for the helper's tests. `cpu` is reached through two samples one second apart.
struct HelperProcess {
    var pid: Int32
    var ppid: Int32 = 1
    var path: String?
    var memory: UInt64? = 10 * HelperFixtures.mib
    var cpu: Double = 0
    var restricted = false
    var signature: CodeSignature? = HelperFixtures.unsigned
    var cwd: String?
}

enum HelperFixtures {
    static let home = "/Users/me"
    static let mib: UInt64 = 1 << 20
    static let unsigned = CodeSignature(signingID: nil, teamID: nil, isPlatformBinary: false)
    static let apple = CodeSignature(signingID: "com.apple.x", teamID: nil, isPlatformBinary: true)
    static let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// Twelve apps, each with its own CPU and memory, plus an app in the home folder, a tool in a project, and two
    /// restricted daemons when `restricted` is set.
    static func workload(restricted: Bool = true) -> [HelperProcess] {
        var processes = (1...12).map { index in
            let memory: UInt64 = UInt64(index) * 100 * mib
            let cpu = Double(13 - index)
            return HelperProcess(pid: Int32(100 + index), path: "/Applications/App\(index).app/Contents/MacOS/App\(index)",
                                 memory: memory, cpu: cpu)
        }
        processes.append(HelperProcess(pid: 200, path: "\(home)/Applications/Local.app/Contents/MacOS/Local",
                                       memory: 5 * mib, cpu: 0.5))
        processes.append(HelperProcess(pid: 300, path: "\(home)/bin/tool", memory: 3 * mib, cpu: 0.25,
                                       cwd: "\(home)/dev/project"))
        if restricted {
            processes += [HelperProcess(pid: 400, path: "/usr/libexec/securityd-like", memory: nil, restricted: true, signature: apple),
                          HelperProcess(pid: 401, path: "/usr/libexec/securityd-like", memory: nil, restricted: true, signature: apple)]
        }
        return processes
    }

    /// A full memory reading: normal pressure, 16 GiB, 1 GiB of swap used of 2, and 4 KiB pages.
    static let memory: RawSystemMemory = {
        var stats = vm_statistics64()
        stats.compressor_page_count = 1000
        stats.wire_count = 2000
        stats.internal_page_count = 5000
        stats.purgeable_count = 1000
        let swap = xsw_usage(xsu_total: 2 << 30, xsu_avail: 1 << 30, xsu_used: 1 << 30, xsu_pagesize: 4096, xsu_encrypted: 1)
        return RawSystemMemory(pressureLevel: withUnsafeBytes(of: Int32(1)) { Array($0) },
                               swapUsage: withUnsafeBytes(of: swap) { Array($0) },
                               memorySize: withUnsafeBytes(of: UInt64(16) << 30) { Array($0) },
                               vmStatistics: stats, pageSize: 4096)
    }()

    static let unreadableMemory = RawSystemMemory(pressureLevel: nil, swapUsage: nil, memorySize: nil, vmStatistics: nil,
                                                  pageSize: nil)

    /// A probe replaying two samples of `processes` one second apart. `listFails` makes listing fail; `ticks` false
    /// makes the host's CPU ticks unreadable.
    static func probe(_ processes: [HelperProcess], listFails: Bool = false, ticks: Bool = true,
                      memory: RawSystemMemory = HelperFixtures.memory) -> ProcessProbe {
        let readers = FixtureSignalReaders()
        for process in processes {
            readers.signatures[process.pid] = process.signature.map { .value($0, source: .codeSigning) }
                ?? .unavailable(.processExited, source: .codeSigning)
            readers.workingDirectories[process.pid] = process.cwd.map { .value($0, source: .vnodePathInfo) }
                ?? .unavailable(.denied, source: .vnodePathInfo)
            readers.terminals[process.pid] = .value(.none, source: .bsdInfo)
        }
        let timebase = MachTimebase(numer: 1, denom: 1)
        func raw(_ timestamp: UInt64, second: Bool) -> RawProcessSample {
            RawProcessSample(timestamp: timestamp, timebase: timebase, processes: processes.map { process in
                let usage: UsageReading
                if process.restricted {
                    usage = .restricted
                } else if let memory = process.memory {
                    let busy = second ? UInt64(process.cpu / 100 * 1e9) : 0
                    usage = .available(RawProcessUsage(physFootprint: memory, userTime: 1_000_000 + busy, systemTime: 0,
                                                       energy: 0, billedEnergy: 0))
                } else {
                    usage = .unavailable
                }
                return RawProcessRecord(identity: ProcessIdentity(pid: process.pid, startTime: 10), ppid: process.ppid,
                                        uid: 501, executablePath: process.path,
                                        name: process.path.map { ($0 as NSString).lastPathComponent } ?? "p\(process.pid)",
                                        usage: usage)
            })
        }
        let samples = listFails ? [] : [raw(1_000_000_000, second: false), raw(2_000_000_000, second: true)]
        let readings: [HostCPUTicks?] = ticks
            ? [HostCPUTicks(user: 100, system: 100, idle: 800, nice: 0), HostCPUTicks(user: 300, system: 100, idle: 1400, nice: 0)]
            : []
        return ProcessProbe(source: FixtureProcessSource(samples), hostCPU: FixtureHostCPUSource(readings),
                            memory: FixtureMemorySource(raw: memory), origin: readers.originReader(),
                            attribution: Attribution(projectMarkers: FixtureProjectMarkers(["\(home)/dev/project": [".git"]]),
                                                     mountTable: FixtureMountTable(), containerVM: nil),
                            launchdJobs: { [] }, interval: .zero, now: { observedAt })
    }

    static func environment(processes: ProcessProbe? = nil, disk: DiskProbe? = nil, home: String = home) -> HelperEnvironment {
        HelperEnvironment(home: home, processes: processes ?? probe(workload()), disk: disk ?? diskProbe(home: home),
                          now: { observedAt })
    }

    static let volume = VolumeSummary(
        values: VolumeCapacityValues(mountPoint: "/", name: "Macintosh HD", capacity: 500_000_000_000,
                                     availableForImportantUsage: 120_000_000_000, available: 100_000_000_000),
        snapshots: .count(2))

    /// Scans with the real scanner, `volume`, and no installed apps, with `home` as the home folder. `slow` keeps the
    /// scan waiting until it is cancelled, then returns the real scan as cancelled. `onProgress` sees the scan's
    /// progress. `includedDocker` records each analysis's Docker flag; `docker` is what Docker answers when asked.
    /// `edit` changes the scanned tree, given its root, to place states a test folder cannot have.
    static func diskProbe(slow: Bool = false, includedDocker: DockerFlags? = nil, home: String = home,
                          volume: VolumeSummary = HelperFixtures.volume,
                          docker: DockerImageUsage = .unavailable(.cliNotFound), apps: InstalledApps = InstalledApps([]),
                          onProgress: (@Sendable (DiskScanProgress) -> Void)? = nil,
                          edit: (@Sendable (inout DiskTree, String) -> Void)? = nil) -> DiskProbe {
        DiskProbe(
            scan: { root in
                let scanned: Result<DiskScanResult, DiskScanError>
                do throws(DiskScanError) {
                    let scanner = DiskScanner(workers: 1, progressInterval: onProgress == nil ? .milliseconds(100) : .zero)
                    var result = try await scanner.scan(URL(fileURLWithPath: root), onProgress: onProgress)
                    if let edit {
                        var tree = result.tree
                        edit(&tree, tree.rootPath)
                        result = DiskScanResult(tree: tree, outcome: result.outcome, unreadablePaths: result.unreadablePaths,
                                                entriesRead: result.entriesRead)
                    }
                    scanned = .success(result)
                } catch {
                    scanned = .failure(error)
                }
                guard slow, case let .success(result) = scanned else { return scanned }
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                return .success(DiskScanResult(tree: result.tree, outcome: .cancelled, unreadablePaths: result.unreadablePaths,
                                               entriesRead: result.entriesRead))
            },
            volume: { _ in volume },
            context: { includeDocker in
                includedDocker?.append(includeDocker)
                let real = realpath(home, nil).map { pointer in
                    defer { free(pointer) }
                    return String(cString: pointer)
                }
                return ReclaimContext(home: real ?? home, now: observedAt, installedApps: apps,
                                      simulatorRuntimes: .installed([]), dockerImages: includeDocker ? docker : nil)
            })
    }
}

final class DockerFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []

    func append(_ flag: Bool) { lock.withLock { flags.append(flag) } }
    var values: [Bool] { lock.withLock { flags } }
}

struct FixtureMemorySource: SystemMemorySource {
    let raw: RawSystemMemory

    func read() -> RawSystemMemory { raw }
}

/// A temporary folder removed when the test ends.
final class TemporaryFolder {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("subset-system-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ relative: String, bytes: Int) throws {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: target)
    }

    func folder(_ relative: String) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    deinit {
        // A folder made unreadable by a test is opened again so it can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator {
                chmod(url.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

extension XCTestCase {
    /// Runs the helper on `arguments` and parses its JSON output.
    func run(_ arguments: [String], _ environment: HelperEnvironment) async -> HelperOutput {
        await HelperRunner.run(arguments, environment: environment)
    }

    func object(_ output: HelperOutput, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
        return try XCTUnwrap(parsed as? [String: Any], file: file, line: line)
    }

    /// Asserts that `output` validates against `schema`.
    func assertValid(_ output: HelperOutput, _ schema: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var validator = SchemaValidator()
        let errors = try validator.errors(json: output.stdout, schemaFile: schema)
        XCTAssertEqual(errors, [], "\(schema): \(output.stdout.prefix(2000))", file: file, line: line)
    }
}
