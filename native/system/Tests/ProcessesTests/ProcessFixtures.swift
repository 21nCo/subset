import Foundation
import SystemCore
import SystemProcesses

/// A recorded process for the window's tests. `cpu` is reached through two real samples two seconds apart, so the
/// snapshot carries it the way the app's sampler does.
struct FixtureProcess {
    var pid: Int32
    var ppid: Int32 = 1
    var path: String?
    var name: String?
    var memory: UInt64?
    var cpu: Double?
    var energy: UInt64?
    var restricted = false
    var signature: CodeSignature?
    var cwd: String?
}

enum ProcessFixtures {
    static let mib: UInt64 = 1 << 20
    static let format = UsageFormat(locale: Locale(identifier: "en_US_POSIX"), home: "/Users/me")
    static let chrome = "/Applications/Google Chrome.app"
    static let ghostty = "/Applications/Ghostty.app"
    static let google = CodeSignature(signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV", isPlatformBinary: false, teamName: "Google LLC")
    static let mitchell = CodeSignature(signingID: "com.mitchellh.ghostty", teamID: "24VZTF6M5V", isPlatformBinary: false)
    static let apple = CodeSignature(signingID: "com.apple.x", teamID: nil, isPlatformBinary: true)
    static let unsigned = CodeSignature(signingID: nil, teamID: nil, isPlatformBinary: false)

    /// Chrome with two helpers, Ghostty running a shell, `claude` in it, and `node` started by `claude` in a project;
    /// an Apple daemon; and a restricted daemon whose usage macOS refuses to reveal.
    static func workload(chromeMemory: UInt64 = 900 * mib) -> [FixtureProcess] {
        let helpers = "\(chrome)/Contents/Frameworks/Google Chrome Framework.framework/Helpers"
        return [
            FixtureProcess(pid: 100, path: "\(chrome)/Contents/MacOS/Google Chrome", memory: chromeMemory, cpu: 10,
                           energy: 4_000_000_000, signature: google),
            FixtureProcess(pid: 101, ppid: 100, path: "\(helpers)/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
                           memory: 300 * mib, cpu: 20, energy: 1_000_000_000, signature: google),
            FixtureProcess(pid: 102, ppid: 100, path: "\(helpers)/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)",
                           memory: 100 * mib, cpu: 5, energy: 500_000_000, signature: google),
            FixtureProcess(pid: 200, path: "\(ghostty)/Contents/MacOS/ghostty", memory: 200 * mib, cpu: 1, energy: 100_000_000,
                           signature: mitchell),
            FixtureProcess(pid: 201, ppid: 200, path: "/bin/zsh", memory: 4 * mib, cpu: 0, energy: 1_000_000, signature: apple,
                           cwd: "/Users/me/dev/subset"),
            FixtureProcess(pid: 202, ppid: 201, path: "/Users/me/.local/share/claude/versions/2.1.304", name: "2.1.304",
                           memory: 400 * mib, cpu: 50, energy: 9_000_000_000, signature: unsigned, cwd: "/Users/me/dev/subset"),
            FixtureProcess(pid: 203, ppid: 202, path: "/opt/homebrew/Cellar/node/24.1.0/bin/node", memory: 250 * mib, cpu: 80,
                           energy: 2_000_000_000, signature: unsigned, cwd: "/Users/me/dev/subset"),
            FixtureProcess(pid: 300, path: "/usr/libexec/exampled", memory: 20 * mib, cpu: 0.5, energy: 10_000_000, signature: apple),
            FixtureProcess(pid: 400, path: "/usr/libexec/securityd-like", restricted: true, signature: apple),
            FixtureProcess(pid: 401, path: "/usr/libexec/securityd-like", restricted: true, signature: apple)
        ]
    }

    /// Samples the processes twice, two seconds apart, and attributes the second sample. The project marker is
    /// `/Users/me/dev/subset/.git`; the launchd plists name `launchdJobs` (by executable) and could not all be read
    /// when `launchdScanFailures` is not empty.
    static func sample(_ processes: [FixtureProcess], observedAt: Date = Date(timeIntervalSince1970: 1_000_000),
                       launchdJobs: [String: [LaunchdJob]] = [:],
                       launchdScanFailures: [LaunchdScanFailure] = []) throws -> ProcessesSample {
        let readers = FixtureSignalReaders()
        readers.launchdJobs = launchdJobs
        readers.launchdScanFailures = launchdScanFailures
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
                    // CPU percent over the two seconds between the samples, where 100 is one core.
                    let busy = second ? UInt64((process.cpu ?? 0) / 100 * 2e9) : 0
                    usage = .available(RawProcessUsage(physFootprint: memory, userTime: 1_000_000 + busy, systemTime: 0,
                                                       energy: process.energy ?? 0, billedEnergy: 0))
                } else {
                    usage = .unavailable
                }
                return RawProcessRecord(
                    identity: ProcessIdentity(pid: process.pid, startTime: 10), ppid: process.ppid, uid: 501,
                    executablePath: process.path,
                    name: process.name ?? process.path.map { ($0 as NSString).lastPathComponent } ?? "p\(process.pid)",
                    usage: usage
                )
            })
        }
        var sampler = Sampler(source: FixtureProcessSource([raw(1_000_000_000, second: false), raw(3_000_000_000, second: true)]),
                              origin: readers.originReader(), logicalCoreCount: 8)
        _ = try sampler.sample()
        let snapshot = try sampler.sample()
        let attribution = Attribution(projectMarkers: FixtureProjectMarkers(["/Users/me/dev/subset": [".git"]]),
                                      mountTable: FixtureMountTable(), containerVM: nil)
            .attribute(snapshot.processes)
        return ProcessesSample(snapshot: snapshot, attribution: attribution, observedAt: observedAt)
    }

    /// A memory reading with only the pressure level and physical memory size.
    static func memory(level: Int32, physical: UInt64) -> SystemMemory {
        SystemMemory(raw: RawSystemMemory(pressureLevel: withUnsafeBytes(of: level) { Array($0) }, swapUsage: nil,
                                          memorySize: withUnsafeBytes(of: physical) { Array($0) }, vmStatistics: nil,
                                          pageSize: nil))
    }

    static func identity(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, startTime: 10) }
}
