import Darwin
import Foundation
@testable import SubsetCore
import XCTest

/// The tool runner with real processes: a process the tool starts is stopped with it (its own process group), and
/// neither one holding the output after the tool exits nor one surviving a cancel makes an operation hang.
final class ToolRunnerTests: XCTestCase {
    func testAToolsStatusAndOutput() async throws {
        let result = try await ToolRunner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(result.stderr, "err\n")
    }

    func testAProcessHoldingTheOutputAfterTheToolExitsIsStoppedSoon() async throws {
        let started = Date()
        let result = try await ToolRunner.run("/bin/sh", ["-c", "sleep 600 & echo $!; exit 0"])
        XCTAssertLessThan(Date().timeIntervalSince(started), ToolRunner.drainAfterExit + ToolRunner.killAfter + 1)
        XCTAssertNil(result.status, "a tool whose helper still holds its output did not finish cleanly")
        XCTAssertTrue(result.stderr.contains("stopped: a process it started still held its output"), result.stderr)
        try assertGone(result)
    }

    func testATimeoutStopsTheToolAndWhatItStarted() async throws {
        let started = Date()
        let result = try await ToolRunner.run("/bin/sh", ["-c", "sleep 600 & echo $!; sleep 600"], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), ToolRunner.killAfter)
        XCTAssertNil(result.status)
        XCTAssertEqual(result.lastLine, "stopped: it did not finish in 0.5 seconds")
        try assertGone(result)
    }

    func testACancelStopsTheToolAndWhatItStartedAndThrows() async throws {
        let task = Task { try await ToolRunner.run("/bin/sh", ["-c", "sleep 600 & sleep 600"]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled tool throws")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), ToolRunner.killAfter)
    }

    func testACleanupIsNotCancelled() async throws {
        let task = Task { try await ToolRunner.run("/bin/sh", ["-c", "sleep 0.3; echo done"], cancellable: false) }
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
    }

    func testOutputPastTheCapIsNotKeptAndAWriterIgnoringSIGTERMStillEnds() async throws {
        let started = Date()
        let result = try await ToolRunner.run("/bin/sh", ["-c", "trap '' TERM; /usr/bin/yes"], timeout: 60)
        XCTAssertLessThan(Date().timeIntervalSince(started), ToolRunner.killAfter, "the closed pipe ends it before SIGKILL")
        XCTAssertNil(result.status)
        XCTAssertLessThanOrEqual(result.stdout.count, ToolRunner.maxOutputBytes)
        XCTAssertTrue(result.stderr.contains("stopped: it wrote more than"), result.stderr)
    }

    func testAStopRacingTheToolsExitAlwaysSettles() async throws {
        for _ in 0..<40 {
            let result = try await ToolRunner.run("/usr/bin/true", [], timeout: 0)
            XCTAssertTrue(result.status == 0 || result.stderr.contains("stopped: it did not finish"), result.stderr)
        }
    }

    func testACancelOrTimeoutStopsWhatTheToolStartedWhetherItKeepsOrClosesTheOutput() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (n, redirect) in ["", " >/dev/null 2>&1"].enumerated() {
            for cancel in [true, false] {
                let file = folder.appendingPathComponent("\(n)-\(cancel)").path
                let task = Task { try await ToolRunner.run("/bin/sh", ["-c", "sleep 600\(redirect) & echo $! > \(file).new && mv \(file).new \(file); sleep 600"], timeout: cancel ? 60 : 3) }
                guard try await waitForFile(file, of: task) else { return }
                if cancel { task.cancel() }
                let result = try? await task.value
                XCTAssertEqual(result == nil, cancel, "a cancel throws, a timeout returns")
                try assertGone(ToolResult(status: nil, stdout: try Data(contentsOf: URL(fileURLWithPath: file)), stderr: ""))
            }
        }
    }

    // The exited tool stays unreaped while a process it started still holds the output, so its pid and its group's ID
    // cannot be reused by another process before the group is stopped; it is reaped once the result is settled.
    func testAnExitedToolKeepsItsPidUntilItsResultIsSettled() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("leader").path
        let task = Task { try await ToolRunner.run("/bin/sh", ["-c", "sleep 600 & echo $$ > \(file).new && mv \(file).new \(file); exit 0"]) }
        guard try await waitForFile(file, of: task) else { return }
        let leader = try XCTUnwrap(pid_t(String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(kill(leader, 0), 0, "the exited tool still holds its pid while its helper holds the output")
        let result = try await task.value
        XCTAssertNil(result.status)
        XCTAssertNotEqual(kill(leader, 0), 0, "reaped once settled")
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Waits up to 10 seconds for the tool to write `file`; when it does not (it failed or was stopped early), the test
    /// fails, and the tool is cancelled and waited for so nothing is left running.
    private func waitForFile(_ file: String, of task: Task<ToolResult, Error>, line: UInt = #line) async throws -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: file) {
            guard Date() < deadline else {
                task.cancel()
                let result = try? await task.value
                XCTFail("the tool did not write \(file): \(result?.stderr ?? "cancelled")", line: line)
                return false
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// The background sleep whose pid the tool printed no longer runs.
    private func assertGone(_ result: ToolResult, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(text), "the printed pid: \(text)", file: file, line: line)
        let until = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < until { usleep(50_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the process the tool started was stopped", file: file, line: line)
    }
}
