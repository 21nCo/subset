import Foundation
import Testing
@testable import TimerApp
@testable import TimerCore

/// A fake `cli serve --json` run by /bin/sh in place of Node: it records each launch, then runs `body`.
private func fakeServe(_ body: String) throws -> (Runtime, launches: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timer-board-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let launches = directory.appendingPathComponent("launches")
    let script = directory.appendingPathComponent("cli.sh")
    try "echo $$ >> '\(launches.path)'\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
    return (Runtime(node: "/bin/sh", nodeVersion: "22.13.0", cli: script.path, cliSource: .override), launches)
}

private func launchCount(_ launches: URL) -> Int {
    ((try? String(contentsOf: launches, encoding: .utf8)) ?? "").split(separator: "\n").count
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    #expect(condition())
}

@Suite(.serialized)
@MainActor
struct BoardTests {
    @Test func openBoardWhileStartingReusesTheStartingProcessAndQuitStopsIt() async throws {
        let (runtime, launches) = try fakeServe("""
            trap 'exit 0' TERM
            sleep 1
            echo '{"url":"http://127.0.0.1:4321/","port":4321}'
            while :; do sleep 1; done
            """)
        let controller = TimerController()
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.openBoard(runtime)
        let process = try #require(controller.board?.process)
        controller.openBoard(runtime)
        #expect(controller.board?.process === process)
        try await eventually { controller.board?.url != nil }
        #expect(controller.board?.url == URL(string: "http://127.0.0.1:4321/"))
        #expect(launchCount(launches) == 1)

        controller.stopBoard()
        try await eventually { controller.board == nil }
        #expect(!process.isRunning)
        #expect(errors.isEmpty)
    }

    @Test func aServeFailureShowsTheCLIErrorItPrintedOnStdout() async throws {
        let (runtime, _) = try fakeServe("""
            echo '{"error":{"code":"invalid_input","message":"Port 4321 is in use. Choose another with --port."}}'
            exit 2
            """)
        let controller = TimerController()
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.openBoard(runtime)
        try await eventually { !errors.isEmpty }
        #expect(errors == ["Port 4321 is in use. Choose another with --port."])
        #expect(controller.board == nil)
    }

    @Test func servedLinesAndFailureMessages() {
        typealias Served = TimerController.Served
        #expect(Served(line: Data(#"{"url":"http://127.0.0.1:4322/","port":4322}"#.utf8)) == .serving(URL(string: "http://127.0.0.1:4322/")!))
        #expect(Served(line: Data(#"{"error":{"code":"internal","message":"No web files."}}"#.utf8)) == .failed("No web files."))
        #expect(Served(line: Data()) == nil)
        #expect(Served(line: Data("Timer is at http://127.0.0.1:4321/".utf8)) == nil)
        #expect(Served.failureMessage(.failed("No web files."), errors: "warning\n", status: 1) == "No web files.")
        #expect(Served.failureMessage(nil, errors: "node: bad option\n", status: 9) == "node: bad option")
        #expect(Served.failureMessage(nil, errors: "", status: 1) == "The Timer board stopped (exit code 1).")
    }
}
