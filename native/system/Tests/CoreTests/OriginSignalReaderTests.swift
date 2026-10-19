import Darwin
import SystemCore
import XCTest

/// `OriginSignalReader` over fixture readers, driven through the `Sampler` as the app drives it.
final class OriginSignalReaderTests: XCTestCase {
    private let timebase = MachTimebase(numer: 1, denom: 1)

    func testEachReaderRunsOncePerIdentityAndAgainForAReusedPID() throws {
        let fixtures = signedFixtures(pids: [10, 11])
        let reader = fixtures.originReader()
        var sampler = Sampler(source: FixtureProcessSource([
            sample([record(10, start: 1), record(11, start: 1)]),
            sample([record(10, start: 1), record(11, start: 1)]),
            // pid 11 exited and the kernel gave its PID to a new process.
            sample([record(10, start: 1), record(11, start: 5)])
        ]), origin: reader)

        let first = try sampler.sample()
        let second = try sampler.sample()

        XCTAssertEqual(first.processes.map(\.origin), second.processes.map(\.origin))
        XCTAssertEqual(second.processes.first?.coalitionID, 1010)
        for pid: pid_t in [10, 11] {
            for kind: FixtureSignalReaders.Reader in [.responsible, .coalition, .codeSignature, .workingDirectory, .terminal] {
                XCTAssertEqual(fixtures.calls(kind, pid: pid), 1, "\(kind) for pid \(pid)")
            }
            XCTAssertEqual(fixtures.launchdCalls(executable: "/usr/bin/p\(pid)"), 1)
        }
        XCTAssertEqual(fixtures.refreshes, 1, "the launchd index is checked only when there is something new to read")

        _ = try sampler.sample()
        XCTAssertEqual(fixtures.calls(.coalition, pid: 10), 1)
        XCTAssertEqual(fixtures.calls(.coalition, pid: 11), 2, "a new identity on a reused PID is read again")
        XCTAssertEqual(fixtures.refreshes, 2)
    }

    func testARestrictedProcessKeepsTheSignalsItsReadersGotAndEachFailureNamesItsReason() throws {
        let fixtures = FixtureSignalReaders()
        // Another user's daemon: macOS denies the responsibility and working-directory reads, and its terminal comes
        // from the process table.
        fixtures.responsible[20] = .unavailable(.denied, source: .responsibility)
        fixtures.coalitions[20] = .value(77, source: .coalitionInfo)
        fixtures.signatures[20] = .value(CodeSignature(signingID: "com.example.daemon", teamID: "ABCDE12345", isPlatformBinary: false), source: .codeSigning)
        fixtures.workingDirectories[20] = .unavailable(.denied, source: .vnodePathInfo)
        fixtures.terminals[20] = .value(.none, source: .processTable)
        fixtures.launchdJobs["/usr/bin/p20"] = [job("com.example.daemon", "/Library/LaunchDaemons/com.example.daemon.plist")]
        var sampler = Sampler(source: FixtureProcessSource([sample([record(20, start: 1, usage: .restricted)])]), origin: fixtures.originReader())

        let facts = try XCTUnwrap(try sampler.sample().processes.first)
        let origin = try XCTUnwrap(facts.origin)

        XCTAssertTrue(facts.restricted)
        XCTAssertEqual(facts.coalitionID, 77)
        XCTAssertEqual(facts.teamID, "ABCDE12345")
        XCTAssertEqual(facts.signingID, "com.example.daemon")
        XCTAssertEqual(facts.isPlatformBinary, false)
        XCTAssertEqual(facts.launchdLabel, "com.example.daemon")
        XCTAssertNil(facts.tty)
        XCTAssertEqual(origin.terminal, .value(.none, source: .processTable))
        XCTAssertNil(facts.responsiblePID)
        XCTAssertNil(facts.workingDirectory)
        XCTAssertEqual(origin.responsibleProcess.failure, .denied)
        XCTAssertEqual(origin.responsibleProcess.source, .responsibility)
        XCTAssertEqual(origin.workingDirectory.failure?.reason, "macOS denied the read")
        XCTAssertEqual(origin.workingDirectory.source, .vnodePathInfo)
    }

    func testAPIDThatChangesHandsDuringTheReadsKeepsNoSignals() throws {
        let fixtures = signedFixtures(pids: [30])
        fixtures.reusedPIDs = [30]
        var sampler = Sampler(source: FixtureProcessSource([sample([record(30, start: 1)])]), origin: fixtures.originReader())

        let origin = try XCTUnwrap(try sampler.sample().processes.first?.origin)

        XCTAssertEqual(origin.coalition, .unavailable(.processExited, source: .coalitionInfo))
        XCTAssertEqual(origin.codeSignature, .unavailable(.processExited, source: .codeSigning))
        XCTAssertEqual(origin.terminal.failure, .processExited)
    }

    func testAProcessThatRunsExecIsReadAgainAsItsNewExecutable() throws {
        // `exec node server.js` from a shell keeps the PID and start time.
        let fixtures = signedFixtures(pids: [90])
        fixtures.signatures[90] = .value(CodeSignature(signingID: "com.apple.sh", teamID: nil, isPlatformBinary: true), source: .codeSigning)
        fixtures.launchdJobs["/usr/local/bin/node"] = [job("dev.server", "/dev.server.plist")]
        let shell = record(90, start: 1, path: "/bin/sh")
        let node = record(90, start: 1, path: "/usr/local/bin/node")
        var sampler = Sampler(source: FixtureProcessSource([sample([shell]), sample([shell]), sample([node]), sample([node])]), origin: fixtures.originReader())

        for _ in 0..<2 {
            let facts = try XCTUnwrap(try sampler.sample().processes.first)
            XCTAssertEqual(facts.signingID, "com.apple.sh")
            XCTAssertEqual(facts.launchdMatch, LaunchdMatch.none)
        }
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 90), 1, "an unchanged executable is read once")

        fixtures.signatures[90] = .value(CodeSignature(signingID: "node", teamID: "HX7739G8FX", isPlatformBinary: false), source: .codeSigning)
        for _ in 0..<2 {
            let facts = try XCTUnwrap(try sampler.sample().processes.first)
            XCTAssertEqual(facts.signingID, "node")
            XCTAssertEqual(facts.origin?.launchdJobs.value?.map(\.label), ["dev.server"])
            XCTAssertEqual(facts.launchdLabel, "dev.server")
        }
        for kind: FixtureSignalReaders.Reader in [.responsible, .coalition, .codeSignature, .workingDirectory, .terminal] {
            XCTAssertEqual(fixtures.calls(kind, pid: 90), 2, "\(kind) once per executable")
        }
        XCTAssertEqual(fixtures.launchdCalls(executable: "/usr/local/bin/node"), 1)
    }

    func testAProcessThatRunsExecDuringItsReadsIsNotCachedAndIsReadAgainNextSample() throws {
        let fixtures = signedFixtures(pids: [91])
        // Sampled as the shell, but running node by the time its reads are checked.
        fixtures.execs[91] = "/usr/local/bin/node"
        var sampler = Sampler(source: FixtureProcessSource([
            sample([record(91, start: 1, path: "/bin/sh")]),
            sample([record(91, start: 1, path: "/usr/local/bin/node")])
        ]), origin: fixtures.originReader())

        XCTAssertNil(try sampler.sample().processes.first?.origin, "not read yet, rather than exited")
        let origin = try XCTUnwrap(try sampler.sample().processes.first?.origin)

        XCTAssertEqual(origin.coalition, .value(1091, source: .coalitionInfo))
        XCTAssertEqual(fixtures.calls(.coalition, pid: 91), 2)
        XCTAssertEqual(fixtures.launchdCalls(executable: "/bin/sh"), 1)
        XCTAssertEqual(fixtures.launchdCalls(executable: "/usr/local/bin/node"), 1)
    }

    func testReadsStopAtTheBudgetOldestFirstAndTheRestFollowNextSample() throws {
        let fixtures = signedFixtures(pids: [40, 41, 42])
        // The clock advances 600 ms per read: the first read is free, the second starts at 600 ms, the third would
        // start at 1.2 s, past the one-second budget.
        let clock = Ticker(step: 600_000_000)
        let reader = fixtures.originReader(now: clock.next)
        let processes = [record(40, start: 30), record(41, start: 10), record(42, start: 20)]
        var sampler = Sampler(source: FixtureProcessSource([sample(processes), sample(processes)]), origin: reader)

        let first = try sampler.sample()
        XCTAssertEqual(first.processes.map { $0.origin != nil }, [false, true, true], "the two oldest are read first")
        XCTAssertNil(first.processes[0].coalitionID)

        let second = try sampler.sample()
        XCTAssertTrue(second.processes.allSatisfy { $0.origin != nil })
        XCTAssertEqual(fixtures.calls(.coalition, pid: 40), 1)
        XCTAssertEqual(fixtures.calls(.coalition, pid: 41), 1)
    }

    func testTheLaunchdLabelIsSetOnlyWhenTheMatchingJobsAgree() throws {
        let fixtures = signedFixtures(pids: [50, 51], platform: false)
        fixtures.launchdJobs["/usr/bin/p50"] = [job("dev.a", "/a.plist"), job("dev.a", "/b.plist")]
        fixtures.launchdJobs["/usr/bin/p51"] = [job("dev.a", "/a.plist"), job("dev.b", "/c.plist")]
        var sampler = Sampler(source: FixtureProcessSource([sample([record(50, start: 1), record(51, start: 1)])]), origin: fixtures.originReader())

        let processes = try sampler.sample().processes

        XCTAssertEqual(processes[0].launchdLabel, "dev.a")
        XCTAssertEqual(processes[0].launchdMatch, .job(label: "dev.a"))
        XCTAssertNil(processes[1].launchdLabel)
        XCTAssertEqual(processes[1].launchdMatch, .executableOnly(.conflictingLabels))
        XCTAssertEqual(processes[1].origin?.launchdJobs.value?.count, 2)
    }

    func testACopyOfAJobsProgramThatLaunchdDidNotStartIsNotTheJob() throws {
        let fixtures = signedFixtures(pids: [60, 61], platform: false)
        for pid: pid_t in [60, 61] {
            fixtures.launchdJobs["/usr/bin/p\(pid)"] = [job("dev.server", "/dev.server.plist")]
        }
        // pid 60 runs under launchd; pid 61 runs the same program from a terminal's shell.
        var sampler = Sampler(
            source: FixtureProcessSource([sample([record(60, start: 1, ppid: 1), record(61, start: 1, ppid: 900)])]),
            origin: fixtures.originReader()
        )

        let processes = try sampler.sample().processes

        XCTAssertEqual(processes[0].launchdLabel, "dev.server")
        XCTAssertNil(processes[1].launchdLabel)
        XCTAssertEqual(processes[1].launchdMatch, .executableOnly(.notStartedByLaunchd))
        XCTAssertEqual(processes[1].origin?.launchdJobs.value?.map(\.label), ["dev.server"], "the raw signal still lists the plist")
    }

    func testAJobWhoseProgramIsAPlatformBinaryLabelsNoProcess() throws {
        // A plist that runs /usr/bin/osascript says nothing about which osascript process is its job, even one
        // launchd started: Apple's own unindexed jobs run platform binaries too.
        let fixtures = signedFixtures(pids: [70, 71])
        fixtures.signatures[71] = .unavailable(.processExited, source: .codeSigning)
        for pid: pid_t in [70, 71] {
            fixtures.launchdJobs["/usr/bin/p\(pid)"] = [job("dev.script", "/dev.script.plist")]
        }
        var sampler = Sampler(source: FixtureProcessSource([sample([record(70, start: 1), record(71, start: 1)])]), origin: fixtures.originReader())

        let processes = try sampler.sample().processes

        XCTAssertEqual(processes.map(\.launchdMatch), Array(repeating: .executableOnly(.sharedExecutable), count: 2))
        XCTAssertEqual(processes.map(\.launchdLabel), [nil, nil])
        XCTAssertEqual(processes[0].origin?.launchdJobs.value?.count, 1)
    }

    func testNoPlistIsNoMatchAndAnUnreadProcessHasNone() throws {
        let fixtures = signedFixtures(pids: [80], platform: false)
        var read = Sampler(source: FixtureProcessSource([sample([record(80, start: 1)])]), origin: fixtures.originReader())
        var unread = Sampler(source: FixtureProcessSource([sample([record(80, start: 1)])]))

        XCTAssertEqual(try read.sample().processes.first?.launchdMatch, LaunchdMatch.none)
        XCTAssertNil(try XCTUnwrap(try unread.sample().processes.first).launchdMatch)
    }

    private func signedFixtures(pids: [pid_t], platform: Bool = true) -> FixtureSignalReaders {
        let fixtures = FixtureSignalReaders()
        for pid in pids {
            fixtures.responsible[pid] = .value(pid, source: .responsibility)
            fixtures.coalitions[pid] = .value(UInt64(pid) + 1000, source: .coalitionInfo)
            fixtures.signatures[pid] = .value(CodeSignature(signingID: "p\(pid)", teamID: platform ? nil : "ABCDE12345", isPlatformBinary: platform), source: .codeSigning)
            fixtures.workingDirectories[pid] = .value("/", source: .vnodePathInfo)
            fixtures.terminals[pid] = .value(.device("ttys00\(pid % 10)"), source: .bsdInfo)
        }
        return fixtures
    }

    private func job(_ label: String, _ plist: String) -> LaunchdJob {
        LaunchdJob(label: label, plistPath: plist, domain: .globalDaemon, program: "/usr/bin/x", resolvedProgram: "/usr/bin/x")
    }

    private func sample(_ processes: [RawProcessRecord]) -> RawProcessSample {
        RawProcessSample(timestamp: 0, timebase: timebase, processes: processes)
    }

    private func record(_ pid: pid_t, start: UInt64, ppid: Int32 = 1, usage: UsageReading = .unavailable, path: String? = nil) -> RawProcessRecord {
        RawProcessRecord(
            identity: ProcessIdentity(pid: pid, startTime: start),
            ppid: ppid,
            uid: 501,
            executablePath: path ?? "/usr/bin/p\(pid)",
            name: "p\(pid)",
            usage: usage
        )
    }
}

/// A clock that advances a fixed step every time it is read.
private final class Ticker: @unchecked Sendable {
    private let step: UInt64
    private let lock = NSLock()
    private var value: UInt64 = 0

    init(step: UInt64) {
        self.step = step
    }

    var next: @Sendable () -> UInt64 {
        { [self] in lock.withLock { defer { value += step }; return value } }
    }
}
