import SystemCore
import XCTest

final class SamplerTests: XCTestCase {
    /// Apple silicon's timebase: 125/3 ns per tick, so 24 million ticks are one second.
    private let appleSilicon = MachTimebase(numer: 125, denom: 3)
    private let ticksPerSecond: UInt64 = 24_000_000

    func testMachTimeConvertsToNanosecondsWithTheTimebase() {
        XCTAssertEqual(appleSilicon.nanoseconds(ticksPerSecond), 1_000_000_000)
        XCTAssertEqual(appleSilicon.nanoseconds(3), 125)
        XCTAssertEqual(MachTimebase(numer: 1, denom: 1).nanoseconds(42), 42)
        // ticks × numer overflows 64 bits here; the full-width product does not.
        XCTAssertEqual(appleSilicon.nanoseconds(UInt64.max / 100), 7_686_143_364_045_646_500)
        XCTAssertEqual(appleSilicon.nanoseconds(.max), .max)
    }

    func testFactsCarryCPUTimeInNanosecondsAndNoOriginSignals() throws {
        var sampler = Sampler(source: FixtureProcessSource([
            sample(at: 0, [record(pid: 10, start: 1, user: 3 * ticksPerSecond, system: ticksPerSecond / 2)])
        ]), logicalCoreCount: 8)

        let facts = try XCTUnwrap(try sampler.sample().processes.first)

        XCTAssertEqual(facts.userCPUTime, 3_000_000_000)
        XCTAssertEqual(facts.systemCPUTime, 500_000_000)
        XCTAssertEqual(facts.physFootprint, 64 << 20)
        XCTAssertEqual(facts.billedEnergy, 7_000_000_000)
        XCTAssertEqual(facts.executablePath, "/usr/bin/p10")
        XCTAssertEqual(facts.ppid, 1)
        XCTAssertEqual(facts.uid, 501)
        XCTAssertNil(facts.cpuPercent, "a first sample has no previous CPU time")
        XCTAssertFalse(facts.restricted)
        let origin: [Any?] = [
            facts.responsiblePID, facts.coalitionID, facts.teamID, facts.signingID, facts.isPlatformBinary,
            facts.launchdLabel, facts.workingDirectory, facts.tty
        ]
        XCTAssertTrue(origin.allSatisfy { $0 == nil })
    }

    func testCPUPercentIsTheCPUTimeDeltaOverTheWallDeltaWithOneCoreAtOneHundred() throws {
        var sampler = Sampler(source: FixtureProcessSource([
            sample(at: 0, [
                record(pid: 10, start: 1, user: 0, system: 0),
                record(pid: 11, start: 1, user: 0, system: 0)
            ]),
            // Two seconds later: pid 10 used three seconds of CPU (1.5 cores), pid 11 half a second.
            sample(at: 2 * ticksPerSecond, [
                record(pid: 10, start: 1, user: 2 * ticksPerSecond, system: ticksPerSecond),
                record(pid: 11, start: 1, user: ticksPerSecond / 2, system: 0)
            ])
        ]), logicalCoreCount: 8)

        _ = try sampler.sample()
        let snapshot = try sampler.sample()

        XCTAssertEqual(try cpu(of: 10, in: snapshot), 150, accuracy: 1e-9)
        XCTAssertEqual(try cpu(of: 11, in: snapshot), 25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snapshot.totalCPUPercent), 175, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snapshot.machineCPUPercent), 175.0 / 8, accuracy: 1e-9)
        XCTAssertEqual(snapshot.logicalCoreCount, 8)
    }

    func testAReusedPIDIsANewProcessWithoutCPUUntilItsSecondSample() throws {
        var sampler = Sampler(source: FixtureProcessSource([
            sample(at: 0, [record(pid: 10, start: 1_000, user: 0, system: 0)]),
            // pid 10 exited and the kernel gave the PID to a new process that has already used a lot of CPU.
            sample(at: ticksPerSecond, [record(pid: 10, start: 2_000, user: 5 * ticksPerSecond, system: 0)]),
            sample(at: 2 * ticksPerSecond, [record(pid: 10, start: 2_000, user: 5 * ticksPerSecond + ticksPerSecond / 4, system: 0)])
        ]), logicalCoreCount: 8)

        _ = try sampler.sample()
        let reused = try sampler.sample()
        XCTAssertEqual(reused.processes.map(\.identity), [ProcessIdentity(pid: 10, startTime: 2_000)])
        XCTAssertNil(reused.processes[0].cpuPercent, "the old process's CPU time must not be subtracted")

        XCTAssertEqual(try cpu(of: 10, in: try sampler.sample()), 25, accuracy: 1e-9)
    }

    func testExitedProcessesAreDroppedAndNewOnesWaitForASecondSample() throws {
        var sampler = Sampler(source: FixtureProcessSource([
            sample(at: 0, [record(pid: 10, start: 1, user: 0, system: 0), record(pid: 11, start: 1, user: 0, system: 0)]),
            sample(at: ticksPerSecond, [record(pid: 11, start: 1, user: ticksPerSecond, system: 0), record(pid: 12, start: 5, user: 0, system: 0)]),
            // pid 10 comes back as the same identity: it was missing for a sample, so it starts over.
            sample(at: 2 * ticksPerSecond, [record(pid: 10, start: 1, user: ticksPerSecond, system: 0), record(pid: 12, start: 5, user: ticksPerSecond, system: 0)])
        ]), logicalCoreCount: 8)

        _ = try sampler.sample()
        let second = try sampler.sample()
        XCTAssertEqual(second.processes.map(\.pid), [11, 12])
        XCTAssertEqual(try cpu(of: 11, in: second), 100, accuracy: 1e-9)
        XCTAssertNil(second.processes[1].cpuPercent)

        let third = try sampler.sample()
        XCTAssertEqual(third.processes.map(\.pid), [10, 12])
        XCTAssertNil(third.processes[0].cpuPercent)
        XCTAssertEqual(try cpu(of: 12, in: third), 100, accuracy: 1e-9)
    }

    func testEPERMKeepsTheProcessAsRestrictedWithUnavailableValues() throws {
        var sampler = Sampler(source: FixtureProcessSource([
            sample(at: 0, [record(pid: 1, start: 1, usage: .restricted), record(pid: 20, start: 1, usage: .unavailable)]),
            sample(at: ticksPerSecond, [record(pid: 1, start: 1, usage: .restricted), record(pid: 20, start: 1, usage: .unavailable)])
        ]), logicalCoreCount: 8)

        _ = try sampler.sample()
        let snapshot = try sampler.sample()

        let restricted = try XCTUnwrap(snapshot.processes.first { $0.pid == 1 })
        XCTAssertTrue(restricted.restricted)
        XCTAssertEqual(restricted.name, "p1")
        XCTAssertEqual(restricted.executablePath, "/usr/bin/p1")
        XCTAssertNil(restricted.physFootprint)
        XCTAssertNil(restricted.userCPUTime)
        XCTAssertNil(restricted.systemCPUTime)
        XCTAssertNil(restricted.billedEnergy)
        XCTAssertNil(restricted.cpuPercent)

        let failed = try XCTUnwrap(snapshot.processes.first { $0.pid == 20 })
        XCTAssertFalse(failed.restricted, "only a denied read is restricted")
        XCTAssertNil(failed.physFootprint)
        XCTAssertNil(snapshot.totalCPUPercent, "no measured process means no total, not 0%")
    }

    func testAFailedReadKeepsThePreviousSampleForTheNextDelta() throws {
        let source = ScriptedSource([
            .success(sample(at: 0, [record(pid: 10, start: 1, user: 0, system: 0)])),
            .failure(ProcessSourceError.listFailed(EAGAIN)),
            .success(sample(at: 4 * ticksPerSecond, [record(pid: 10, start: 1, user: 2 * ticksPerSecond, system: 0)]))
        ])
        var sampler = Sampler(source: source, logicalCoreCount: 8)

        _ = try sampler.sample()
        XCTAssertThrowsError(try sampler.sample()) { XCTAssertEqual($0 as? ProcessSourceError, .listFailed(EAGAIN)) }
        XCTAssertEqual(try cpu(of: 10, in: try sampler.sample()), 50, accuracy: 1e-9)
    }

    func testCadenceIsTwoSecondsWithTheWindowAndTenWithOnlyTheMenuBar() {
        XCTAssertEqual(SamplingCadence(mainWindowVisible: true).interval, .seconds(2))
        XCTAssertEqual(SamplingCadence(mainWindowVisible: false).interval, .seconds(10))
        // Opening the window 5 s after a menu-bar sample samples now; 1 s after, it waits for the 2 s interval.
        XCTAssertEqual(SamplingCadence.mainWindowVisible.delay(sinceLastSample: .seconds(5)), .zero)
        XCTAssertEqual(SamplingCadence.mainWindowVisible.delay(sinceLastSample: .seconds(1)), .seconds(1))
        XCTAssertEqual(SamplingCadence.menuBarOnly.delay(sinceLastSample: .seconds(2)), .seconds(8))
        XCTAssertEqual(SamplingCadence.menuBarOnly.delay(sinceLastSample: nil), .zero)
    }

    // MARK: - Fixtures

    private func sample(at ticks: UInt64, _ processes: [RawProcessRecord]) -> RawProcessSample {
        RawProcessSample(timestamp: ticks, timebase: appleSilicon, processes: processes)
    }

    private func record(pid: Int32, start: UInt64, user: UInt64, system: UInt64) -> RawProcessRecord {
        record(pid: pid, start: start, usage: .available(RawProcessUsage(
            physFootprint: 64 << 20,
            userTime: user,
            systemTime: system,
            billedEnergy: 7_000_000_000
        )))
    }

    private func record(pid: Int32, start: UInt64, usage: UsageReading) -> RawProcessRecord {
        RawProcessRecord(
            identity: ProcessIdentity(pid: pid, startTime: start),
            ppid: 1,
            uid: 501,
            executablePath: "/usr/bin/p\(pid)",
            name: "p\(pid)",
            usage: usage
        )
    }

    private func cpu(of pid: Int32, in snapshot: ProcessSnapshot) throws -> Double {
        try XCTUnwrap(snapshot.processes.first { $0.pid == pid }?.cpuPercent)
    }
}

/// Returns scripted results in order, including failures.
private final class ScriptedSource: ProcessSource, @unchecked Sendable {
    private var results: [Result<RawProcessSample, any Error>]

    init(_ results: [Result<RawProcessSample, any Error>]) {
        self.results = results
    }

    func sample() throws -> RawProcessSample {
        try results.removeFirst().get()
    }
}
