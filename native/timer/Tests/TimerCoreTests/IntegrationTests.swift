import Foundation
import Testing
@testable import TimerCore

/// Runs only when `SUBSET_TIMER_CLI_PATH` names a built `cli.mjs` (CI sets it after `npm run build`).
private let cliPath = ProcessInfo.processInfo.environment["SUBSET_TIMER_CLI_PATH"].flatMap { $0.isEmpty ? nil : $0 }

@Test(.enabled(if: cliPath != nil, "set SUBSET_TIMER_CLI_PATH to packages/timer-cli/dist/cli.mjs"), .timeLimit(.minutes(1)))
func realDaemonStartsATabataAndStreamsState() async throws {
    let runtime = try await RuntimeLocator(resources: nil).locate().get()
    #expect(runtime.cliSource == .override)
    // A short folder of its own: the socket path must stay under 104 bytes.
    var template = Array("/tmp/subset-timer-XXXXXX".utf8CString)
    let dataDir = String(cString: try #require(mkdtemp(&template)))
    let paths = DaemonPaths(dataDir: (dataDir as NSString).appendingPathComponent("timer"))
    let client = DaemonClient(paths: paths)
    defer { try? FileManager.default.removeItem(atPath: dataDir) }
    await #expect(throws: DaemonError.notListening) { try await client.info() }

    let environment = ProcessInfo.processInfo.environment.merging(["SUBSET_TIMER_ALERTS": "off"]) { $1 }
    try await client.ensureRunning(timeout: 10) {
        try DaemonLauncher.launch(node: runtime.node, cli: runtime.cli, paths: paths, environment: environment)
    }
    let info = try await client.info()
    #expect(info.socket == paths.socket)
    #expect(DaemonLock.held(at: paths.lock))
    #expect(info.alerts == "off")

    // The first state event shows the empty board; starting a Tabata publishes the next.
    let updates = EventSubscription.updates(connect: { try await client.openEvents() })
    var boards: [TimerBoard] = []
    var started: TimerResult?
    for await update in updates {
        guard case .event(let event) = update, event.event == "state" else { continue }
        boards.append(try DaemonClient.board(from: Data(event.data.utf8)))
        if boards.count == 1 {
            #expect(boards[0].timers.isEmpty)
            started = try await client.perform("start", OperationInput(preset: "tabata"))
        } else {
            break
        }
    }
    let tabata = try #require(boards.last?.timers.first)
    #expect(tabata.definition.name == "Tabata")
    #expect(tabata.runtime.status == .running)
    #expect(tabata.definition.id == started?.timer.definition.id)
    #expect(try await client.board().timers.map(\.definition.id) == [tabata.definition.id])

    // A rejected operation reports the daemon's error.
    await #expect(throws: DaemonError.self) { try await client.perform("lap", OperationInput(id: tabata.definition.id)) }
    _ = try await client.perform("remove", OperationInput(id: tabata.definition.id), as: RemovedResult.self)

    // A daemon asked for while the old one is still shutting down replaces it once it has released the lock.
    #expect(try await client.send("POST", "/v1/shutdown").status == 200)
    // A reply the closing daemon cuts short is not a refusal; wait for it to refuse or say it is shutting down.
    for _ in 0..<100 {
        do { _ = try await client.info() } catch DaemonError.notListening, DaemonError.shuttingDown { break } catch {}
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try await client.ensureRunning(timeout: 10) {
        try DaemonLauncher.launch(node: runtime.node, cli: runtime.cli, paths: paths, environment: environment)
    }
    #expect(try await client.info().pid != info.pid)

    // The daemon keeps running on its own until it is told to stop.
    let reply = try await client.send("POST", "/v1/shutdown")
    #expect(reply.status == 200)
    for _ in 0..<50 where FileManager.default.fileExists(atPath: paths.socket) { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(!FileManager.default.fileExists(atPath: paths.socket))
    for _ in 0..<50 where DaemonLock.held(at: paths.lock) { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(!DaemonLock.held(at: paths.lock))

    // While a live process holds the lock the daemon exits "already running"; once it is gone, a second launch runs.
    let holder = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    try "\(holder.processIdentifier)\n".write(toFile: paths.lock, atomically: true, encoding: .utf8)
    let refused = "already running (pid \(holder.processIdentifier))"
    let release = Task {
        for _ in 0..<100 where !((try? String(contentsOfFile: paths.log, encoding: .utf8))?.contains(refused) ?? false) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        holder.terminate()
        holder.waitUntilExit()
    }
    try await client.ensureRunning(timeout: 10) {
        try DaemonLauncher.launch(node: runtime.node, cli: runtime.cli, paths: paths, environment: environment)
    }
    try await release.value
    #expect(try String(contentsOfFile: paths.log, encoding: .utf8).contains(refused))
    #expect(try await client.send("POST", "/v1/shutdown").status == 200)
}
