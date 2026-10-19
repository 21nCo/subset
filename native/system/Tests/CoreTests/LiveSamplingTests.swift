import Darwin
import SystemCore
import XCTest

/// Samples this Mac through libproc. Runs in CI on macOS.
final class LiveSamplingTests: XCTestCase {
    func testSamplesItsOwnProcessTwiceWithAFootprintAndCPU() throws {
        var sampler = Sampler(source: LibprocProcessSource(), hostCPU: LiveHostCPUSource())
        let pid = getpid()

        let first = try sampler.sample()
        let mine = try XCTUnwrap(first.processes.first { $0.pid == pid }, "the test process is not in the sample")
        XCTAssertFalse(mine.restricted)
        XCTAssertGreaterThan(try XCTUnwrap(mine.physFootprint), 0)
        XCTAssertEqual(mine.uid, getuid())
        XCTAssertEqual(mine.ppid, getppid())
        XCTAssertEqual(mine.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       Bundle.main.executableURL?.resolvingSymlinksInPath().path)
        XCTAssertFalse(mine.name.isEmpty)
        XCTAssertNil(mine.cpuPercent)
        XCTAssertNil(first.machineCPUPercent)

        // Burn some CPU so the second sample has a measurable delta. The kernel folds ticks into the host counters
        // lazily (gaps near a second are normal on an idle Mac), so keep spinning until they have moved.
        let hostCPU = LiveHostCPUSource()
        let firstTicks = try XCTUnwrap(hostCPU.read())
        let minimum = Date().addingTimeInterval(0.2)
        let deadline = Date().addingTimeInterval(5)
        var spin = 0
        while Date() < minimum || (hostCPU.read() == firstTicks && Date() < deadline) { spin &+= 1 }
        XCTAssertNotEqual(spin, 0)

        let second = try sampler.sample()
        let again = try XCTUnwrap(second.processes.first { $0.pid == pid })
        XCTAssertEqual(again.identity, mine.identity, "the start time is stable across samples")
        XCTAssertGreaterThan(try XCTUnwrap(again.physFootprint), 0)
        XCTAssertGreaterThan(try XCTUnwrap(again.cpuPercent), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(again.totalCPUTime), try XCTUnwrap(mine.totalCPUTime))
        XCTAssertGreaterThan(second.logicalCoreCount, 0)
        // The host's ticks saw this process spin, so the machine was measurably busy, and never more than all of it.
        let machine = try XCTUnwrap(second.machineCPUPercent)
        XCTAssertGreaterThan(machine, 0)
        XCTAssertLessThanOrEqual(machine, 100)

        // launchd (pid 1) belongs to root: it must be listed with an identity even though its usage is denied.
        let launchd = try XCTUnwrap(second.processes.first { $0.pid == 1 })
        XCTAssertEqual(launchd.uid, 0)
        if getuid() != 0 {
            XCTAssertTrue(launchd.restricted)
            XCTAssertNil(launchd.physFootprint)
        }
        XCTAssertEqual(Set(second.processes.map(\.identity)).count, second.processes.count)
    }
}
