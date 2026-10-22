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
}
