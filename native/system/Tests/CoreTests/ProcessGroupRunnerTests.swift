import Darwin
import Foundation
@testable import SystemCore
import XCTest

/// `ProcessGroupRunner` with stub `/bin/sh` scripts that start a child of their own: an answer comes only once the
/// command and its child have exited, after a normal exit, a timeout, a cancellation, or a shutdown, and the group is
/// sent `SIGKILL` when it ignores `SIGTERM`.
final class ProcessGroupRunnerTests: XCTestCase {
    private var folder: URL!
    private var pidFile: String { folder.appendingPathComponent("pid").path }
    private var childFile: String { folder.appendingPathComponent("child").path }

    /// A script that ignores `SIGTERM`, as does the `sleep` it starts (an ignored signal stays ignored across exec), and
    /// writes both pids.
    private var stubborn: String {
        "trap '' TERM\nsleep 30 &\necho $! > '\(childFile)'\necho $$ > '\(pidFile)'\nwait"
    }

    /// A script that ignores `SIGTERM` and starts four `yes` writers, which ignore it too, and writes its pid and the
    /// last writer's.
    private var flood: String {
        "trap '' TERM\nfor i in 1 2 3 4; do yes & done\necho $! > '\(childFile)'\necho $$ > '\(pidFile)'\nwait"
    }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProcessGroupRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for file in [pidFile, childFile] {
            if let pid = try? pid(file) { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    func testACommandAnswersOnlyOnceAProgramItLeftRunningHasExited() async throws {
        let stub = try await warmedStub("""
        echo out; echo err >&2
        (sleep 1; echo done > '\(folder.appendingPathComponent("marker").path)') &
        echo $! > '\(childFile)'
        exit 4
        """)

        let result = await ProcessGroupRunner().run(stub, arguments: [], environment: [:], timeout: .seconds(30))

        let output = try result.get()
        XCTAssertEqual(output.status, 4)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "err\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("marker").path),
                      "the background child finished before the answer")
        assertGone(try pid(childFile), "the child")
    }

    func testATimedOutCommandThatIgnoresSIGTERMIsKilledWithItsChildBeforeItAnswers() async throws {
        let stub = try await warmedStub(stubborn)
        let started = ContinuousClock.now

        let result = await ProcessGroupRunner(grace: .milliseconds(400)).run(stub, arguments: [], environment: [:],
                                                                            timeout: .milliseconds(300))

        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(700), "SIGTERM alone did not stop them")
        assertGone(try pid(pidFile), "the command")
        assertGone(try pid(childFile), "its child")
    }

    func testACancelledCommandAnswersOnlyOnceItAndItsChildHaveExited() async throws {
        let stub = try await warmedStub(stubborn)
        let run = Task {
            await ProcessGroupRunner(grace: .milliseconds(500)).run(stub, arguments: [], environment: [:], timeout: .seconds(30))
        }
        let pids = try await waitForPIDs()
        let cancelled = ContinuousClock.now
        run.cancel()

        let result = await run.value

        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - cancelled, .milliseconds(500), "it waited for SIGKILL")
        assertGone(pids.command, "the command")
        assertGone(pids.child, "its child")
    }

    func testShuttingDownKillsTheWholeGroupAtOnceAndStartsNoMore() async throws {
        let stub = try await warmedStub(stubborn)
        let registry = CommandRegistry()
        let run = Task {
            await ProcessGroupRunner(grace: .seconds(30), registry: registry).run(stub, arguments: [], environment: [:],
                                                                                 timeout: .seconds(30))
        }
        let pids = try await waitForPIDs()
        let started = ContinuousClock.now

        registry.shutDown()

        let result = await run.value
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "SIGKILL was sent at once, not after the grace")
        assertGone(pids.command, "the command")
        assertGone(pids.child, "its child")
        try FileManager.default.removeItem(atPath: pidFile)
        let after = await ProcessGroupRunner(registry: registry).run(stub, arguments: [], environment: [:], timeout: .seconds(5))
        XCTAssertEqual(after, .failure(.cancelled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile), "the refused command was never started")
    }

    func testALaunchFailureRunawayOutputAndAnAlreadyCancelledTask() async throws {
        let plain = folder.appendingPathComponent("plain").path
        try "echo nope".write(toFile: plain, atomically: true, encoding: .utf8)
        guard case .failure(.launchFailed) = await ProcessGroupRunner().run(plain, arguments: [], environment: [:],
                                                                           timeout: .seconds(5)) else {
            return XCTFail("a file that is not executable launched")
        }

        let chatty = try await warmedStub("echo $$ > '\(pidFile)'\nexec yes")
        let flood = await ProcessGroupRunner(outputLimit: 64 << 10).run(chatty, arguments: [], environment: [:],
                                                                       timeout: .seconds(10))
        XCTAssertEqual(flood, .failure(.outputTooLarge))
        assertGone(try pid(pidFile), "the command stopped past the cap")

        try FileManager.default.removeItem(atPath: pidFile)
        let never = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ProcessGroupRunner().run(chatty, arguments: [], environment: [:], timeout: .seconds(5))
        }
        let notStarted = await never.value
        XCTAssertEqual(notStarted, .failure(.cancelled))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile), "nothing was started")
    }

    /// Several writers that ignore `SIGTERM` keep the pipe full: a stop, the deadline, and the output cap are still
    /// noticed, and the group is sent `SIGKILL` after the grace, rather than the output being read for as long as it lasts.
    func testAFloodPastTheCapIsKilledAfterTheGrace() async throws {
        let stub = try await warmedStub(flood)
        let started = ContinuousClock.now

        let turns = Turns()
        var runner = ProcessGroupRunner(outputLimit: 64 << 10, grace: .milliseconds(300))
        runner.onTurn = { turns.add($0, $1) }

        let result = await answer(within: .seconds(10)) { [runner] in
            await runner.run(stub, arguments: [], environment: [:], timeout: .seconds(60))
        }

        XCTAssertEqual(result, .failure(.outputTooLarge))
        // A turn reads one chunk of each stream, the last read a bounded number, and no more than a byte past the cap
        // is ever kept, however much the writers produce.
        let all = turns.all
        XCTAssertGreaterThan(all.count, 1)
        XCTAssertLessThanOrEqual(all.dropLast().map(\.read).max() ?? 0, 2 * ProcessGroupRunner.chunkSize)
        XCTAssertLessThanOrEqual(all.last?.read ?? 0, 2 * ProcessGroupRunner.finalChunks * ProcessGroupRunner.chunkSize)
        XCTAssertLessThanOrEqual(all.map(\.kept).max() ?? 0, (64 << 10) + 1)
        XCTAssertGreaterThan(all.map(\.read).reduce(0, +), 64 << 10, "the output past the cap was read and dropped")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(300), "SIGTERM alone did not stop them")
        assertGone(try pid(pidFile), "the command")
        assertGone(try pid(childFile), "a writer")
    }

    func testACancelledFloodAnswersOnceTheGroupIsKilled() async throws {
        let stub = try await warmedStub(flood)
        let run = Task {
            await ProcessGroupRunner(outputLimit: 1 << 30, grace: .milliseconds(300))
                .run(stub, arguments: [], environment: [:], timeout: .seconds(60))
        }
        let pids = try await waitForPIDs()
        let cancelled = ContinuousClock.now
        run.cancel()

        let result = await answer(within: .seconds(5)) { await run.value }

        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - cancelled, .milliseconds(300), "it waited for SIGKILL")
        assertGone(pids.command, "the command")
        assertGone(pids.child, "a writer")
    }

    func testATimedOutFloodAnswersOnceTheGroupIsKilled() async throws {
        let stub = try await warmedStub(flood)
        let started = ContinuousClock.now

        let result = await answer(within: .seconds(5)) {
            await ProcessGroupRunner(outputLimit: 1 << 30, grace: .milliseconds(300))
                .run(stub, arguments: [], environment: [:], timeout: .milliseconds(300))
        }

        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(600), "SIGTERM alone did not stop them")
        assertGone(try pid(pidFile), "the command")
        assertGone(try pid(childFile), "a writer")
    }

    func testTheEnvironmentIsExactlyTheOneGiven() async throws {
        let output = try await ProcessGroupRunner().run("/usr/bin/env", arguments: [], environment: ["SUBSET_TEST": "1"],
                                                        timeout: .seconds(10)).get()
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "SUBSET_TEST=1\n", "nothing is inherited")
    }

    func testOnlyARunThatStartedTheProgramSaysItLaunched() async throws {
        let stub = try await warmedStub(stubborn)
        // Cancelled before the launch, and refused after a shutdown: nothing starts, and the result says so.
        let never = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ProcessGroupRunner().run(stub, arguments: [], environment: [:], workingDirectory: "/",
                                                  timeout: .seconds(5))
        }
        let cancelled = await never.value
        XCTAssertEqual(cancelled, GroupCommandResult(ending: .failure(.cancelled), launched: false))
        let registry = CommandRegistry()
        registry.shutDown()
        let refused = await ProcessGroupRunner(registry: registry).run(stub, arguments: [], environment: [:],
                                                                       workingDirectory: "/", timeout: .seconds(5))
        XCTAssertEqual(refused, GroupCommandResult(ending: .failure(.cancelled), launched: false))
        let missing = await ProcessGroupRunner().run(folder.appendingPathComponent("missing").path, arguments: [],
                                                     environment: [:], workingDirectory: "/", timeout: .seconds(5))
        guard case .failure(.launchFailed) = missing.ending else { return XCTFail("\(missing)") }
        XCTAssertFalse(missing.launched)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile), "nothing was started")

        // Stopped while it runs: it was launched.
        let run = Task {
            await ProcessGroupRunner(grace: .milliseconds(300)).run(stub, arguments: [], environment: [:],
                                                                    workingDirectory: "/", timeout: .seconds(30))
        }
        let pids = try await waitForPIDs()
        run.cancel()
        let stopped = await run.value
        XCTAssertEqual(stopped.ending, .failure(.cancelled))
        XCTAssertTrue(stopped.launched)
        assertGone(pids.command, "the command")
        assertGone(pids.child, "its child")
    }

    func testTheCommandRunsInTheWorkingDirectoryGiven() async throws {
        let inside = folder.appendingPathComponent("inside").path
        try FileManager.default.createDirectory(atPath: inside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inside + "/only-file", contents: Data())
        let result = await ProcessGroupRunner().run("/bin/ls", arguments: [], environment: [:], workingDirectory: inside,
                                                    timeout: .seconds(10))
        XCTAssertEqual(result.ending, .success(0))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "only-file\n")
    }

    // MARK: Helpers

    private final class Turns: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(read: Int, kept: Int)] = []
        func add(_ read: Int, _ kept: Int) { lock.withLock { recorded.append((read, kept)) } }
        var all: [(read: Int, kept: Int)] { lock.withLock { recorded } }
    }

    /// The process is gone right now, not merely on its way out.
    private func assertGone(_ pid: pid_t, _ name: String) {
        XCTAssertEqual(kill(pid, 0), -1, "\(name) is still running")
        XCTAssertEqual(errno, ESRCH, name)
    }

    private func pid(_ file: String) throws -> pid_t {
        let text = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text))
    }

    private func waitForPIDs() async throws -> (command: pid_t, child: pid_t) {
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: pidFile), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))
        return (try pid(pidFile), try pid(childFile))
    }

    /// The run's answer; if it has not answered within `bound`, the test fails and the group is killed so that it ends.
    private func answer(within bound: Duration,
                        _ run: @escaping @Sendable () async -> Result<CommandOutput, CommandFailure>) async
        -> Result<CommandOutput, CommandFailure> {
        let pidFile = pidFile
        let watchdog = Task {
            try await Task.sleep(for: bound)
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                killpg(pid, SIGKILL)
            }
        }
        let result = await run()
        watchdog.cancel()
        if (try? await watchdog.value) != nil { XCTFail("no answer within \(bound)") }
        return result
    }

    /// A stub run once already, so the first run's malware scan cannot hold it past a short timeout.
    private func warmedStub(_ body: String) async throws -> String {
        let path = folder.appendingPathComponent("stub-\(UUID().uuidString)").path
        try "#!/bin/sh\n[ \"$1\" = warm ] && exit 0\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(path, 0o755), 0)
        let warm = await ProcessGroupRunner().run(path, arguments: ["warm"], environment: [:], timeout: .seconds(30))
        XCTAssertEqual(try warm.get().status, 0)
        return path
    }
}
