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

    // MARK: - Fixtures

    private func basics(start: UInt64, name: String) -> Basics {
        Basics(identity: ProcessIdentity(pid: 50, startTime: start), ppid: 1, uid: 501, name: name)
    }

    private func usage(footprint: UInt64) -> UsageReading {
        .available(RawProcessUsage(physFootprint: footprint, userTime: 0, systemTime: 0, billedEnergy: 0))
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
