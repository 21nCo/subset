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
        XCTAssertEqual(facts.energy, 7_000_000_000, "the process's own energy comes from ri_energy_nj")
        XCTAssertEqual(facts.billedEnergy, 3_000_000, "energy billed for others' work stays a separate figure")
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
        XCTAssertNil(restricted.energy)
        XCTAssertNil(restricted.billedEnergy)
        XCTAssertNil(restricted.cpuPercent)

        let failed = try XCTUnwrap(snapshot.processes.first { $0.pid == 20 })
        XCTAssertFalse(failed.restricted, "only a denied read is restricted")
        XCTAssertNil(failed.physFootprint)
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

    func testMachineCPUComesFromHostTicksAndCountsRestrictedProcesses() throws {
        // Every process is restricted, so no per-process CPU exists, yet the host ticks still measure the machine.
        var sampler = Sampler(
            source: FixtureProcessSource([
                sample(at: 0, [record(pid: 1, start: 1, usage: .restricted)]),
                sample(at: ticksPerSecond, [record(pid: 1, start: 1, usage: .restricted)])
            ]),
            hostCPU: FixtureHostCPUSource([
                ticks(user: 1_000, system: 500, idle: 8_000, nice: 0),
                // 400 ticks passed: 220 user, 60 system, 20 nice, 100 idle, so 75% busy.
                ticks(user: 1_220, system: 560, idle: 8_100, nice: 20)
            ]),
            logicalCoreCount: 4
        )

        let first = try sampler.sample()
        XCTAssertNil(first.machineCPUPercent, "a first sample has no previous ticks")
        XCTAssertTrue(first.isFirstSample)
        let snapshot = try sampler.sample()
        XCTAssertFalse(snapshot.isFirstSample)
        XCTAssertNil(snapshot.processes[0].cpuPercent)
        XCTAssertEqual(try XCTUnwrap(snapshot.machineCPUPercent), 75, accuracy: 1e-9)
    }

    func testHostTickWrapResetOrStallIsUnavailableAndTheNextIntervalRecovers() throws {
        let start = ticks(user: 100, system: 100, idle: 100, nice: 0)
        XCTAssertEqual(try XCTUnwrap(HostCPUTicks.busyPercent(from: start, to: ticks(user: 150, system: 100, idle: 150, nice: 0))), 50)
        XCTAssertEqual(HostCPUTicks.busyPercent(from: start, to: ticks(user: 100, system: 100, idle: 200, nice: 0)), 0)
        XCTAssertNil(HostCPUTicks.busyPercent(from: start, to: start), "no tick passed")
        let nearWrap = ticks(user: .max - 10, system: 100, idle: 100, nice: 0)
        XCTAssertNil(HostCPUTicks.busyPercent(from: nearWrap, to: ticks(user: 5, system: 110, idle: 120, nice: 0)), "a wrapped counter")
        XCTAssertNil(HostCPUTicks.busyPercent(from: start, to: ticks(user: 5, system: 5, idle: 5, nice: 0)), "a reset")

        var sampler = Sampler(
            source: FixtureProcessSource((0..<5).map { sample(at: UInt64($0) * ticksPerSecond, []) }),
            hostCPU: FixtureHostCPUSource([
                start,
                ticks(user: 10, system: 10, idle: 10, nice: 0), // reset
                nil, // failed read
                ticks(user: 20, system: 10, idle: 20, nice: 0),
                ticks(user: 30, system: 10, idle: 50, nice: 0)
            ]),
            logicalCoreCount: 8
        )
        let percents = try (0..<5).map { _ in try sampler.sample().machineCPUPercent }
        XCTAssertEqual(percents, [nil, nil, nil, nil, 25])
    }

    func testCadenceIsTwoSecondsWithTheWindowAndTenWithOnlyTheMenuBar() {
        XCTAssertEqual(SamplingCadence(mainWindowVisible: true).interval, .seconds(2))
        XCTAssertEqual(SamplingCadence(mainWindowVisible: false).interval, .seconds(10))

        let now = ContinuousClock.now
        var schedule = SamplingSchedule()
        XCTAssertEqual(schedule.delay(for: .menuBarOnly, now: now), .zero, "the first sample starts at once")
        XCTAssertTrue(schedule.begin(at: now))
        schedule.finish()
        // Opening the window 5 s after a menu-bar sample samples now; 1 s after, it waits for the 2 s interval.
        XCTAssertEqual(schedule.delay(for: .mainWindowVisible, now: now + .seconds(5)), .zero)
        XCTAssertEqual(schedule.delay(for: .mainWindowVisible, now: now + .seconds(1)), .seconds(1))
        XCTAssertEqual(schedule.delay(for: .menuBarOnly, now: now + .seconds(2)), .seconds(8))
    }

    func testACadenceChangeDuringASampleNeitherOverlapsNorFollowsItAtOnce() {
        let now = ContinuousClock.now
        var schedule = SamplingSchedule()
        XCTAssertTrue(schedule.begin(at: now))

        // The window opens while that sample is still running: no second sample starts alongside or right behind it.
        XCTAssertFalse(schedule.begin(at: now + .milliseconds(10)))
        XCTAssertEqual(schedule.delay(for: .mainWindowVisible, now: now + .milliseconds(10)), .seconds(2))
        schedule.finish()
        XCTAssertEqual(schedule.delay(for: .mainWindowVisible, now: now + .milliseconds(50)), .milliseconds(1_950))
        XCTAssertEqual(schedule.lastStart, now)
    }

    // MARK: - Fixtures

    private func sample(at ticks: UInt64, _ processes: [RawProcessRecord]) -> RawProcessSample {
        RawProcessSample(timestamp: ticks, timebase: appleSilicon, processes: processes)
    }

    private func ticks(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) -> HostCPUTicks {
        HostCPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    private func record(pid: Int32, start: UInt64, user: UInt64, system: UInt64) -> RawProcessRecord {
        record(pid: pid, start: start, usage: .available(RawProcessUsage(
            physFootprint: 64 << 20,
            userTime: user,
            systemTime: system,
            energy: 7_000_000_000,
            billedEnergy: 3_000_000
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
