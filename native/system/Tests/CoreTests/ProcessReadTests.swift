import Darwin
@testable import SystemCore
import XCTest

/// `LibprocProcessSource.read` with scripted PID-keyed reads, to cover a PID changing hands mid-read.
final class ProcessReadTests: XCTestCase {
    private typealias Basics = LibprocProcessSource.ProcessBasics

    func testAPIDReusedMidReadIsReadAgainAsTheNewProcess() throws {
        // The first identity read sees the old process; by the second the kernel has given pid 50 to a new one, whose
        // counters and path the first usage and path reads may already have returned.
        let script = Script(
            basics: [basics(start: 1_000, name: "old"), basics(start: 2_000, name: "new"), basics(start: 2_000, name: "new"), basics(start: 2_000, name: "new")],
            usage: [usage(footprint: 9), usage(footprint: 7)],
            paths: ["/usr/bin/new", "/usr/bin/new"]
        )

        let record = try XCTUnwrap(LibprocProcessSource.read(50, with: script.reads))

        XCTAssertEqual(record.identity, ProcessIdentity(pid: 50, startTime: 2_000))
        XCTAssertEqual(record.name, "new")
        XCTAssertEqual(record.executablePath, "/usr/bin/new")
        XCTAssertEqual(record.usage, usage(footprint: 7))
    }

    func testAPIDThatKeepsChangingHandsIsLeftForTheNextSample() {
        let script = Script(
            basics: [basics(start: 1, name: "a"), basics(start: 2, name: "b"), basics(start: 2, name: "b"), basics(start: 3, name: "c")],
            usage: [usage(footprint: 1), usage(footprint: 2)],
            paths: ["/a", "/b"]
        )

        XCTAssertNil(LibprocProcessSource.read(50, with: script.reads))
    }

    func testAProcessThatExitsMidReadIsLeftOut() {
        let script = Script(basics: [basics(start: 1, name: "a")], usage: [usage(footprint: 1)], paths: ["/a"])

        XCTAssertNil(LibprocProcessSource.read(50, with: script.reads))
    }

    func testAStableProcessIsReadOnce() throws {
        let script = Script(
            basics: [basics(start: 1, name: ""), basics(start: 1, name: "")],
            usage: [.restricted],
            paths: ["/usr/sbin/daemon"]
        )

        let record = try XCTUnwrap(LibprocProcessSource.read(50, with: script.reads))

        XCTAssertEqual(record.identity, ProcessIdentity(pid: 50, startTime: 1))
        XCTAssertEqual(record.usage, .restricted)
        XCTAssertEqual(record.name, "daemon", "an empty name falls back to the executable's file name")
        XCTAssertEqual(script.remaining, 0)
    }

    func testANameTheKernelCutShortIsTakenFromTheExecutable() throws {
        // pbi_name keeps 31 bytes and the p_comm fallback for another user's process 16.
        let cases = [
            ("com.apple.quicklook.ThumbnailsA", "/System/Library/Frameworks/QuickLookThumbnailing.framework/Support/com.apple.quicklook.ThumbnailsAgent", "com.apple.quicklook.ThumbnailsAgent"),
            ("mobileactivation", "/usr/libexec/mobileactivationd", "mobileactivationd"),
        ]
        for (kernelName, path, expected) in cases {
            let script = Script(basics: [basics(start: 1, name: kernelName), basics(start: 1, name: kernelName)], usage: [.restricted], paths: [path])

            XCTAssertEqual(try XCTUnwrap(LibprocProcessSource.read(50, with: script.reads)).name, expected)
        }
    }

    func testAKernelNameThatIsNotCutShortIsKept() throws {
        let cases: [(kernelName: String, path: String?)] = [
            ("Google Chrome Helper", "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/chrome_crashpad_handler"),
            ("node", "/usr/local/bin/node"),
            ("loginwindow", nil),
        ]
        for (kernelName, path) in cases {
            let script = Script(
                basics: [basics(start: 1, name: kernelName), basics(start: 1, name: kernelName)],
                usage: [.restricted],
                paths: path.map { [$0] } ?? []
            )

            XCTAssertEqual(try XCTUnwrap(LibprocProcessSource.read(50, with: script.reads)).name, kernelName)
        }
    }

    func testAPIDListThatFillsTheBufferIsReadAgainWithMoreRoom() throws {
        // The list grew between the count and the buffered read: a full buffer may be cut short, so it is read again
        // with twice the count plus headroom.
        let list = ScriptedPIDList([(10, 0), (74, 0), (80, 0)])

        let pids = try LibprocProcessSource.listPIDs(with: list.call)

        XCTAssertEqual(pids.count, 80)
        XCTAssertEqual(list.bufferSizes, [74, 212].map { Int32($0 * MemoryLayout<pid_t>.stride) })
    }

    func testAFailedPIDListThatLibprocReportsAsZeroThrows() {
        // libproc turns a failed __proc_info into a count of 0, never -1.
        let list = ScriptedPIDList([(3, 0), (0, EPERM)])

        XCTAssertThrowsError(try LibprocProcessSource.listPIDs(with: list.call)) {
            XCTAssertEqual($0 as? ProcessSourceError, .listFailed(EPERM))
        }
        XCTAssertThrowsError(try LibprocProcessSource.listPIDs(with: ScriptedPIDList([(0, EPERM)]).call)) {
            XCTAssertEqual($0 as? ProcessSourceError, .listFailed(EPERM))
        }
    }

    func testAFailedPIDListKeepsTheSamplersPreviousSample() throws {
        // pid 50's CPU time grows every read; a failed list in between must not reset its baseline to an empty sample.
        let list = ScriptedPIDList([(1, 0), (1, 0), (1, 0), (0, EAGAIN), (1, 0), (1, 0)])
        let script = Script(
            basics: Array(repeating: basics(start: 1, name: "p"), count: 4),
            usage: [usage(footprint: 1, userTime: 0), usage(footprint: 1, userTime: 1_000_000)],
            paths: ["/p", "/p"]
        )
        var sampler = Sampler(source: LibprocProcessSource(listAllPIDs: list.call, reads: script.reads), logicalCoreCount: 8)

        XCTAssertNil(try sampler.sample().processes.first?.cpuPercent)
        XCTAssertThrowsError(try sampler.sample()) { XCTAssertEqual($0 as? ProcessSourceError, .listFailed(EAGAIN)) }
        let process = try XCTUnwrap(try sampler.sample().processes.first { $0.pid == 50 })
        XCTAssertNotNil(process.cpuPercent, "the delta is taken against the sample before the failure")
    }

    // MARK: - Fixtures

    private func basics(start: UInt64, name: String) -> Basics {
        Basics(identity: ProcessIdentity(pid: 50, startTime: start), ppid: 1, uid: 501, name: name)
    }

    private func usage(footprint: UInt64, userTime: UInt64 = 0) -> UsageReading {
        .available(RawProcessUsage(physFootprint: footprint, userTime: userTime, systemTime: 0, billedEnergy: 0))
    }
}

/// Returns each read's scripted results in order; a read past the end means the process is gone.
private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var basics: [LibprocProcessSource.ProcessBasics]
    private var usage: [UsageReading]
    private var paths: [String]

    init(basics: [LibprocProcessSource.ProcessBasics], usage: [UsageReading], paths: [String]) {
        self.basics = basics
        self.usage = usage
        self.paths = paths
    }

    var remaining: Int { lock.withLock { basics.count + usage.count + paths.count } }

    var reads: LibprocProcessSource.Reads {
        LibprocProcessSource.Reads(
            basics: { _ in self.lock.withLock { self.basics.isEmpty ? nil : self.basics.removeFirst() } },
            usage: { _ in self.lock.withLock { self.usage.isEmpty ? nil : self.usage.removeFirst() } },
            executablePath: { _ in self.lock.withLock { self.paths.isEmpty ? nil : self.paths.removeFirst() } }
        )
    }
}

/// Answers each `proc_listallpids` call with a scripted count and `errno`, writing pid 50 into a buffered call.
private final class ScriptedPIDList: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [(count: Int32, errno: Int32)]
    private var sizes: [Int32] = []

    init(_ results: [(count: Int32, errno: Int32)]) {
        self.results = results
    }

    /// The byte size of each buffered call.
    var bufferSizes: [Int32] { lock.withLock { sizes } }

    var call: LibprocProcessSource.ListAllPIDs {
        { buffer, size in
            self.lock.withLock {
                if buffer != nil { self.sizes.append(size) }
                let result = self.results.isEmpty ? (count: 0, errno: ESRCH) : self.results.removeFirst()
                if let buffer, result.count > 0 { buffer[0] = 50 }
                return result
            }
        }
    }
}
