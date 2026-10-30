import Foundation
import Testing
@testable import TimerCore

/// A fake file system and process runner that records what the locator asked, in order.
private final class FakeSystem: RuntimeSystem, @unchecked Sendable {
    var executables: [String: String] = [:]
    var files: Set<String> = []
    var shellOutput: String?
    private let lock = NSLock()
    private var log: [String] = []
    var calls: [String] { lock.withLock { log } }

    func isExecutable(_ path: String) -> Bool { executables[path] != nil }

    func fileExists(_ path: String) -> Bool {
        lock.withLock { log.append("exists \(path)") }
        return files.contains(path)
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> String? {
        lock.withLock { log.append("run \(executable) \(arguments.joined(separator: " ")) \(Int(timeout))s") }
        return arguments == ["--version"] ? executables[executable] : shellOutput
    }
}

private let bundled = "/Applications/Timer.app/Contents/Resources/timer-cli/dist/cli.mjs"

private func locator(_ system: FakeSystem, environment: [String: String] = ["SHELL": "/bin/zsh"]) -> RuntimeLocator {
    RuntimeLocator(environment: environment, resources: "/Applications/Timer.app/Contents/Resources", system: system)
}

@Test func homebrewNodeComesFirstAndTheBundledCLIIsUsed() async throws {
    let system = FakeSystem()
    system.executables = ["/opt/homebrew/bin/node": "v22.13.0\n", "/usr/local/bin/node": "v24.0.0"]
    system.files = [bundled]
    let runtime = try await locator(system).locate().get()
    #expect(runtime == Runtime(node: "/opt/homebrew/bin/node", nodeVersion: "v22.13.0", cli: bundled, cliSource: .bundled))
    #expect(system.calls == ["run /opt/homebrew/bin/node --version 5s", "exists \(bundled)"])
}

@Test func anOldNodeDoesNotHideANewerOneAndTheLoginShellComesLast() async throws {
    let system = FakeSystem()
    system.executables = ["/opt/homebrew/bin/node": "v22.12.0", "/Users/me/.nvm/versions/node/v24.1.0/bin/node": "v24.1.0"]
    // Profile output before the path, as an interactive login shell may print.
    system.shellOutput = "Welcome back\n/Users/me/.nvm/versions/node/v24.1.0/bin/node\n"
    system.files = [bundled]
    let runtime = try await locator(system, environment: ["SHELL": "/opt/homebrew/bin/fish"]).locate().get()
    #expect(runtime.node == "/Users/me/.nvm/versions/node/v24.1.0/bin/node")
    #expect(system.calls == [
        "run /opt/homebrew/bin/node --version 5s",
        "run /opt/homebrew/bin/fish -ilc command -v node 5s",
        "run /Users/me/.nvm/versions/node/v24.1.0/bin/node --version 5s",
        "exists \(bundled)"
    ])
}

@Test func noSupportedNodeIsASetupProblem() async {
    let system = FakeSystem()
    system.executables = ["/usr/local/bin/node": "v21.7.3"]
    // The shell finds only the same old Node, or times out (nil); either way Node is missing.
    for output in ["/usr/local/bin/node\n", nil] {
        system.shellOutput = output
        #expect(await locator(system).locate() == .failure(.nodeMissing))
    }
    #expect(!system.calls.contains { $0.hasPrefix("exists") })
    #expect(RuntimeProblem.nodeMissing.message == "Node.js 22.13 or later is required")
}

@Test func theCLIOverrideWinsOverTheBundledCopy() async throws {
    let system = FakeSystem()
    system.executables = ["/opt/homebrew/bin/node": "v23.0.0"]
    system.files = [bundled, "/repo/packages/timer-cli/dist/cli.mjs"]
    let runtime = try await locator(system, environment: ["SUBSET_TIMER_CLI_PATH": "/repo/packages/timer-cli/dist/cli.mjs"]).locate().get()
    #expect(runtime.cli == "/repo/packages/timer-cli/dist/cli.mjs")
    #expect(runtime.cliSource == .override)
    #expect(!system.calls.contains("exists \(bundled)"))

    // An override that names nothing is reported, not silently replaced by the bundled copy.
    #expect(await locator(system, environment: ["SUBSET_TIMER_CLI_PATH": "/missing/cli.mjs"]).locate() == .failure(.overrideMissing("/missing/cli.mjs")))
    system.files = []
    #expect(await locator(system).locate() == .failure(.bundledMissing(bundled)))
}

@Test func theDataDirectoryFollowsTheCLI() {
    #expect(DaemonPaths.resolve(environment: [:], home: "/Users/me").socket == "/Users/me/.local/share/subset/timer/daemon.sock")
    // As paths.mjs does: an absolute override as given, a relative one resolved against the working directory.
    #expect(DaemonPaths.resolve(environment: ["SUBSET_TIMER_DATA_DIR": "/data/t/../timer"], home: "/Users/me").dataDir == "/data/t/../timer")
    #expect(DaemonPaths.resolve(environment: ["SUBSET_TIMER_DATA_DIR": "data/../timer/"], home: "/Users/me", workingDirectory: "/work/dir").dataDir == "/work/dir/timer")
    #expect(DaemonPaths.resolve(environment: ["SUBSET_TIMER_DATA_DIR": ""], home: "/Users/me").dataDir == "/Users/me/.local/share/subset/timer")
    // The files are joined lexically, as path.join does, so the client connects where the daemon binds.
    let override = DaemonPaths.resolve(environment: ["SUBSET_TIMER_DATA_DIR": "/data/link/../timer/./"], home: "/Users/me")
    #expect([override.socket, override.log, override.lock] == ["/data/timer/daemon.sock", "/data/timer/daemon.log", "/data/timer/daemon.lock"])
    #expect(DaemonPaths.join("/..", "a/../../b") == "/b")
    #expect(DaemonPaths.join("a", "../../b") == "../b")
}

/// A short temporary folder of its own; the caller removes it.
private func temporaryFolder() throws -> String {
    var template = Array("/tmp/subset-timer-XXXXXX".utf8CString)
    return String(cString: try #require(mkdtemp(&template)))
}

@Test func theDataFolderIsCheckedBeforeTheLogIsWritten() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let launch = { (dataDir: String) in try DaemonLauncher.launch(node: "/nonexistent/node", cli: "cli.mjs", paths: DaemonPaths(dataDir: dataDir)) }
    let refusal = { (reason: String) in DaemonLauncher.LaunchError.dataDirectory(reason) }

    let long = root + "/" + String(repeating: "d", count: 103 - root.utf8.count - "/daemon.sock".utf8.count)
    #expect(throws: refusal("The socket path \(long)/daemon.sock is longer than 103 bytes; set SUBSET_TIMER_DATA_DIR to a shorter directory.")) { try launch(long) }
    #expect(!FileManager.default.fileExists(atPath: long))

    let target = root + "/target", link = root + "/link"
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    #expect(throws: refusal("\(link) is not a directory.")) { try launch(link) }
    #expect(!FileManager.default.fileExists(atPath: target + "/daemon.log"))

    // A loose folder is tightened to 0700 before the log is opened; the missing node then fails the spawn.
    let loose = root + "/loose"
    try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    #expect(throws: DaemonLauncher.LaunchError.spawn(ENOENT)) { try launch(loose) }
    #expect(try FileManager.default.attributesOfItem(atPath: loose)[.posixPermissions] as? Int == 0o700)
}

@Test func aLockCountsOnlyWhileItsHolderLives() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let lock = root + "/daemon.lock"
    let held = { (text: String) in
        try text.write(toFile: lock, atomically: true, encoding: .utf8)
        return DaemonLock.held(at: lock)
    }
    #expect(try held("\(getpid())\n\(String(repeating: "a", count: 32))\nps-Thu_Oct_22_07:00:00_2026\n"))
    #expect(try held("\(getpid())\n"))
    #expect(try !held("99999999\n"))
    #expect(try !held("\(getpid())"))
    #expect(try !held("0\n"))
    try FileManager.default.removeItem(atPath: lock)
    #expect(!DaemonLock.held(at: lock))
}

/// Records launches and probes for `ensureRunning`, with a script of probe results.
private final class FakeDaemons: @unchecked Sendable {
    var probes: [Result<Void, DaemonError>]
    var launched: [LaunchedDaemon] = []
    var lockHeld = true
    var onProbe: (FakeDaemons, Int) -> Void = { _, _ in }
    private(set) var probeCount = 0

    init(probes: [Result<Void, DaemonError>]) {
        self.probes = probes
    }

    func probe(_ timeout: TimeInterval) throws {
        #expect(timeout <= 10)
        onProbe(self, probeCount)
        probeCount += 1
        try (probes.isEmpty ? .failure(.notListening) : probes.removeFirst()).get()
    }

    func launch() -> LaunchedDaemon {
        launched.append(LaunchedDaemon(pid: pid_t(launched.count + 1)))
        return launched.last!
    }

    func run(_ client: DaemonClient, timeout: TimeInterval, lockedExtra: TimeInterval = 0.5) async throws {
        try await client.ensureRunning(timeout: timeout, lockedExtra: lockedExtra, maxLaunches: 3, probe: { try self.probe($0) },
                                       lockHeld: { self.lockHeld }, launch: { self.launch() })
    }
}

@Test func aDaemonShuttingDownIsReplacedOnceItReleasesTheLock() async throws {
    let client = DaemonClient(paths: DaemonPaths(dataDir: "/nonexistent"))
    let fake = FakeDaemons(probes: [.failure(.shuttingDown), .failure(.shuttingDown), .failure(.shuttingDown), .failure(.notListening), .failure(.notListening), .success(())])
    fake.onProbe = { fake, index in
        // The first child exits "already running" while the old daemon still holds the lock, which it then releases.
        if index == 2 { fake.launched[0].markExited() }
        if index == 4 { fake.lockHeld = false }
        #expect(fake.launched.count == (index == 0 ? 0 : index < 5 ? 1 : 2), "probe \(index)")
    }
    try await fake.run(client, timeout: 3)
    #expect(fake.launched.count == 2)
    #expect(fake.probeCount == 6)
}

@Test func ensureRunningGivesUpAfterThreeLaunchesAndItsDeadline() async throws {
    let client = DaemonClient(paths: DaemonPaths(dataDir: "/nonexistent"))
    let fake = FakeDaemons(probes: [])
    fake.lockHeld = false
    // Every child exits at once.
    fake.onProbe = { fake, _ in fake.launched.forEach { $0.markExited() } }
    let start = ContinuousClock.now
    await #expect(throws: DaemonError.notListening) { try await fake.run(client, timeout: 0.6) }
    #expect(fake.launched.count == 3)
    #expect(ContinuousClock.now - start < .seconds(2))
    // A child that keeps running is never replaced, nor is one that exited while a live process holds the lock.
    let running = FakeDaemons(probes: [])
    running.lockHeld = false
    await #expect(throws: DaemonError.notListening) { try await running.run(client, timeout: 0.3) }
    #expect(running.launched.count == 1)
    let locked = FakeDaemons(probes: [])
    locked.onProbe = { fake, _ in fake.launched.forEach { $0.markExited() } }
    await #expect(throws: DaemonError.notListening) { try await locked.run(client, timeout: 0.3) }
    #expect(locked.launched.count == 1)
}

/// A daemon shutting down holds the lock until its sink has finished what it is playing (up to 6 s), so the wait goes on
/// past `timeout` while a live process holds the lock, and the daemon launched once it lets go gets the whole timeout.
@Test func ensureRunningWaitsPastItsTimeoutWhileALiveProcessHoldsTheLock() async throws {
    let client = DaemonClient(paths: DaemonPaths(dataDir: "/nonexistent"))
    let fake = FakeDaemons(probes: [])
    let start = ContinuousClock.now
    fake.onProbe = { fake, _ in
        fake.launched.forEach { $0.markExited() }
        if ContinuousClock.now - start > .milliseconds(600) { fake.lockHeld = false }
        if fake.launched.count == 2 { fake.probes = [.success(())] }
    }
    try await fake.run(client, timeout: 0.3, lockedExtra: 2)
    #expect(fake.launched.count == 2)
    #expect(ContinuousClock.now - start >= .milliseconds(600))
    // Never past `lockedExtra`, however long the lock is held.
    let held = FakeDaemons(probes: [])
    let heldStart = ContinuousClock.now
    await #expect(throws: DaemonError.notListening) { try await held.run(client, timeout: 0.2, lockedExtra: 0.3) }
    #expect(ContinuousClock.now - heldStart >= .milliseconds(500) && ContinuousClock.now - heldStart < .seconds(2))
}

@Test func aProbeReturnsItsOutput() async {
    #expect(await ProcessRuntimeSystem().run("/bin/sh", ["-c", "echo v22.13.0"], timeout: 5) == "v22.13.0\n")
    #expect(await ProcessRuntimeSystem().run("/bin/sh", ["-c", "echo v22.13.0; exit 1"], timeout: 5) == nil)
}

@Test func aTimedOutProbeEndsItsWholeProcessGroup() async throws {
    // A shell and its child that ignore SIGTERM and both hold the output pipe, as a slow login shell might.
    let pids = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: pids) }
    let started = ContinuousClock.now
    let output = await ProcessRuntimeSystem().run("/bin/sh", ["-c", "trap '' TERM; sleep 30 & echo $$ $! > '\(pids)'; wait"], timeout: 0.5)
    #expect(output == nil)
    #expect(ContinuousClock.now - started < .seconds(2))
    let both = try String(contentsOfFile: pids, encoding: .utf8).split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    #expect(both.count == 2)
    // The operating system, not the probe, says whether they still run.
    var alive = both
    for _ in 0..<60 where !alive.isEmpty {
        try await Task.sleep(for: .milliseconds(50))
        alive = alive.filter { kill($0, 0) == 0 }
    }
    #expect(alive.isEmpty, "still running: \(alive)")
    alive.forEach { kill($0, SIGKILL) }
}

@Test func aProbeThatClosesItsOutputEarlyDoesNotSpin() async throws {
    // It closes stdout, then keeps running: its output still counts, and the closed pipe costs no further reads.
    let started = ContinuousClock.now
    let finished = await ProcessRuntimeSystem().probe("/bin/sh", ["-c", "echo v22.13.0; exec 1>&-; sleep 1"], timeout: 5)
    #expect(finished.output == "v22.13.0\n")
    #expect(ContinuousClock.now - started >= .seconds(1))
    #expect(finished.reads < 10, "read \(finished.reads) times")

    // Past its deadline, its process group still ends.
    let pid = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: pid) }
    let timedOut = await ProcessRuntimeSystem().probe("/bin/sh", ["-c", "trap '' TERM; echo $$ > '\(pid)'; exec 1>&-; sleep 30"], timeout: 0.5)
    #expect(timedOut.output == nil)
    #expect(timedOut.reads < 10, "read \(timedOut.reads) times")
    let shell = try #require(Int32(String(contentsOfFile: pid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    var alive = true
    for _ in 0..<60 where alive {
        try await Task.sleep(for: .milliseconds(50))
        alive = kill(shell, 0) == 0
    }
    #expect(!alive, "still running: \(shell)")
    if alive { kill(shell, SIGKILL) }
}
