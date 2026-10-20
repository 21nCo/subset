import CryptoKit
import Darwin
@testable import SystemCore
import XCTest

/// The Docker CLI run through a stub executable: success, timeout, a non-zero exit, a missing binary, the current
/// context check, and the poller's rate limit and visibility rule.
final class DockerCLITests: XCTestCase {
    private var folder: URL!
    private var home: String { folder.appendingPathComponent("home").path }
    private var runLog: String { folder.appendingPathComponent("runs.log").path }
    private var hostLog: String { folder.appendingPathComponent("hosts.log").path }
    private var pidFile: String { folder.appendingPathComponent("pid").path }
    /// The current context's endpoint unless a test sets another: Colima's, so the stub runs without depending on
    /// this Mac's `/var/run/docker.sock`.
    private var colimaHost: String { "unix://\(home)/.colima/default/docker.sock" }
    /// The endpoint the commands are pinned to: the socket's real path (the temporary folder is under `/private`).
    private var colimaEndpoint: String { "unix://" + resolved(home + "/.colima/default/docker.sock") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DockerCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try makeSocket(home + "/.colima/default/docker.sock")
        try writeContext("colima", host: colimaHost)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Stub runs

    func testAStubCLIsOutputBecomesABreakdown() async throws {
        let stub = try makeStub("""
        echo "$*" >> '\(runLog)'
        case "$1" in
          ps) echo '{"ID":"3f2a9c1b7d4e","Names":"shop-db-1","Image":"postgres:16","Labels":"com.docker.compose.project=shop"}' ;;
          stats) echo '{"ID":"3f2a9c1b7d4e","Name":"shop-db-1","CPUPerc":"2.50%","MemUsage":"100MiB / 2GiB"}' ;;
        esac
        """)
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let report = await cli([stub]).report(at: date)

        XCTAssertEqual(try runs(), ["ps --format {{json .}}", "stats --no-stream --format {{json .}}"])
        XCTAssertEqual(report.observedAt, date)
        XCTAssertEqual(report.executable, stub)
        XCTAssertEqual(report.context, DockerContext(name: "colima", host: colimaHost, endpoint: colimaEndpoint, runtime: .colima))
        XCTAssertEqual(try hosts(), [colimaEndpoint, colimaEndpoint])
        guard case let .breakdown(breakdown) = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertEqual(breakdown.projects.map(\.name), ["shop"])
        XCTAssertEqual(breakdown.totals.memoryUsed.sum, 104_857_600)
        XCTAssertEqual(breakdown.totals.cpuPercent.sum, 2.5)
    }

    func testBothCommandsArePinnedToTheEndpointCheckedBeforeTheRun() async throws {
        let orb = home + "/.orbstack/run/docker.sock"
        try makeSocket(orb)
        try writeContext("orbstack", host: "unix://\(orb)")
        // Between the commands the current context becomes a remote one.
        let stub = try makeStub("""
        echo "$1" >> '\(runLog)'
        if [ "$1" = ps ]; then
          printf '{"currentContext":"prod"}' > '\(home)/.docker/config.json'
          echo '{"ID":"3f2a9c1b7d4e","Names":"db","Labels":""}'
        else
          echo '{"ID":"3f2a9c1b7d4e","Name":"db","CPUPerc":"1.00%","MemUsage":"1MiB / 1GiB"}'
        fi
        """)

        let report = await cli([stub]).report()

        XCTAssertEqual(try runs(), ["ps", "stats"])
        let endpoint = "unix://" + resolved(orb)
        XCTAssertEqual(try hosts(), [endpoint, endpoint], "stats reaches the same socket as ps, not the new context")
        XCTAssertEqual(report.context?.host, "unix://\(orb)")
        XCTAssertEqual(report.context?.endpoint, endpoint)
        XCTAssertEqual(report.context?.runtime, .orbStack)
        guard case .breakdown = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertEqual(DockerCLI.arguments(DockerCLI.listingArguments, host: "unix:///var/run/docker.sock"),
                       ["--host", "unix:///var/run/docker.sock", "ps", "--format", "{{json .}}"])
    }

    func testBothCommandsArePinnedToTheSocketALinkReachedWhenChecked() async throws {
        let orb = home + "/.orbstack/run/docker.sock"
        let desktop = home + "/.docker/run/docker.sock"
        try makeSocket(orb)
        try makeSocket(desktop)
        let link = folder.appendingPathComponent("docker.sock").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: orb)
        try writeContext("default-like", host: "unix://\(link)")
        // Between the commands Docker Desktop repoints the shared link at its own socket.
        let stub = try makeStub("""
        echo "$1" >> '\(runLog)'
        if [ "$1" = ps ]; then
          ln -sfh '\(desktop)' '\(link)'
          echo '{"ID":"3f2a9c1b7d4e","Names":"db","Labels":""}'
        else
          echo '{"ID":"3f2a9c1b7d4e","Name":"db","CPUPerc":"1.00%","MemUsage":"1MiB / 1GiB"}'
        fi
        """)

        let report = await cli([stub]).report()

        XCTAssertEqual(try runs(), ["ps", "stats"])
        XCTAssertEqual(resolved(link), resolved(desktop), "the link was repointed during the poll")
        let endpoint = "unix://" + resolved(orb)
        XCTAssertEqual(try hosts(), [endpoint, endpoint], "both commands reach OrbStack's socket, not the link")
        XCTAssertEqual(report.context, DockerContext(name: "default-like", host: "unix://\(link)", endpoint: endpoint, runtime: .orbStack))
        guard case .breakdown = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertEqual(report.status(of: .dockerDesktop), .otherContext(name: "default-like", runtime: .orbStack))
    }

    func testAContextWhoseSocketDoesNotExistIsNotAsked() async throws {
        try FileManager.default.removeItem(atPath: home + "/.colima/default/docker.sock")
        let stub = try makeStub("echo \"$1\" >> '\(runLog)'")

        let report = await cli([stub]).report()

        XCTAssertEqual(report.context, DockerContext(name: "colima", host: colimaHost, endpoint: nil, runtime: .colima,
                                                     missingSocket: home + "/.colima/default/docker.sock"))
        XCTAssertEqual(report.status(of: .colima),
                       .unavailable(.daemonNotRunning(message: "No socket at \(home)/.colima/default/docker.sock.")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runLog), "the CLI never ran")
    }

    func testADanglingDefaultLinkNamesTheRuntimeWhoseDaemonIsStopped() async throws {
        // No current context. Docker Desktop's engine is stopped: the default link, through a relative second link,
        // still names its socket, which is gone.
        try FileManager.default.removeItem(atPath: home + "/.docker/config.json")
        let defaultLink = folder.appendingPathComponent("var-run-docker.sock").path
        let second = folder.appendingPathComponent("second.sock").path
        try FileManager.default.createSymbolicLink(atPath: defaultLink, withDestinationPath: second)
        try FileManager.default.createSymbolicLink(atPath: second, withDestinationPath: "home/.docker/run/docker.sock")
        let stub = try makeStub("echo \"$1\" >> '\(runLog)'")

        let report = await cli([stub], defaultHost: "unix://\(defaultLink)").report()

        let socket = folder.path + "/home/.docker/run/docker.sock"
        XCTAssertEqual(report.context, DockerContext(name: "default", host: "unix://\(defaultLink)", endpoint: nil,
                                                     runtime: .dockerDesktop, missingSocket: socket))
        let stopped = ContainerUnavailable.daemonNotRunning(message: "No socket at \(socket).")
        XCTAssertEqual(report.status(of: .dockerDesktop), .unavailable(stopped))
        XCTAssertEqual(report.status(of: .orbStack), .otherContext(name: "default", runtime: .dockerDesktop))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runLog), "the CLI never ran")
    }

    func testADefaultContextWithNoSocketAtAllSaysTheDaemonIsNotRunning() async throws {
        try "{\"currentContext\":\"default\"}".write(toFile: home + "/.docker/config.json", atomically: true, encoding: .utf8)
        let absent = folder.appendingPathComponent("docker.sock").path
        let stub = try makeStub("echo \"$1\" >> '\(runLog)'")
        let poller = ContainerPoller(cli: cli([stub], defaultHost: "unix://\(absent)"))

        let refreshed = await poller.refresh(cadence: .mainWindowVisible, runningRuntimes: [.orbStack])
        let report = try XCTUnwrap(refreshed)

        XCTAssertEqual(report.context, DockerContext(name: "default", host: "unix://\(absent)", endpoint: nil, runtime: nil, missingSocket: absent))
        XCTAssertEqual(report.status(of: .orbStack), .unavailable(.daemonNotRunning(message: "No socket at \(absent).")),
                       "no daemon, not an unrecognized context")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runLog), "the CLI never ran")
    }

    func testTheCLIRunsWithoutTheCallersDockerEnvironment() async throws {
        setenv("DOCKER_HOST", "tcp://203.0.113.9:2376", 1)
        setenv("DOCKER_CONTEXT", "remote", 1)
        defer { unsetenv("DOCKER_HOST"); unsetenv("DOCKER_CONTEXT") }
        let stub = try makeStub("""
        [ "$1" = ps ] && env | sort >> '\(runLog)'
        exit 0
        """)

        _ = await cli([stub]).report()

        let environment = try runs()
        XCTAssertTrue(environment.contains("HOME=\(home)"), "\(environment)")
        XCTAssertTrue(environment.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertFalse(environment.contains { $0.hasPrefix("DOCKER_HOST=") || $0.hasPrefix("DOCKER_CONTEXT=") || $0.hasPrefix("DOCKER_CONFIG=") })
    }

    func testACommandPastTheTimeoutIsStoppedAndReported() async throws {
        let stub = try makeStub("""
        echo "$1" >> '\(runLog)'
        exec sleep 30
        """)
        let started = ContinuousClock.now

        let report = await cli([stub], timeout: .milliseconds(300)).report()

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the report does not wait for the command")
        XCTAssertEqual(report.outcome, .unavailable(.timedOut(command: "docker ps", seconds: 0.3)))
        // The first run of a new script may be held for a malware scan past the timeout, so the log may be empty.
        XCTAssertFalse(((try? runs()) ?? []).contains("stats"), "stats is not run after ps fails")
        XCTAssertEqual(DockerCLI.timeout, .seconds(5))
        XCTAssertEqual(DockerCLI.commandName(DockerCLI.statsArguments), "docker stats")
        XCTAssertEqual(ContainerUnavailable.timedOut(command: "docker ps", seconds: 5).reason, "docker ps did not finish within 5 seconds.")
    }

    func testAStoppedDaemonAndOtherFailuresGiveTheirReason() async throws {
        let stopped = try makeStub("""
        echo 'Cannot connect to the Docker daemon at unix:///Users/me/.docker/run/docker.sock. Is the docker daemon running?' >&2
        exit 1
        """, name: "stopped")
        let failing = try makeStub("""
        [ "$1" = ps ] && exit 0
        printf '\\n  unknown flag: --no-stream\\nSee docker stats --help\\n' >&2
        exit 125
        """, name: "failing")

        let stoppedReport = await cli([stopped]).report()
        let failingReport = await cli([failing]).report()
        let newerCLI = try makeStub("""
        echo 'failed to connect to the docker API at unix:///Users/me/.colima/default/docker.sock; check if the path is correct and if the daemon is running: dial unix /Users/me/.colima/default/docker.sock: connect: no such file or directory' >&2
        exit 1
        """, name: "newer")
        let newerReport = await cli([newerCLI]).report()
        guard case .unavailable(.daemonNotRunning) = newerReport.outcome else {
            return XCTFail("Docker CLI 28's message is a stopped daemon")
        }

        XCTAssertEqual(stoppedReport.outcome, .unavailable(.daemonNotRunning(
            message: "Cannot connect to the Docker daemon at unix:///Users/me/.docker/run/docker.sock. Is the docker daemon running?")))
        XCTAssertEqual(failingReport.outcome, .unavailable(.failed(command: "docker stats", status: 125, message: "unknown flag: --no-stream")))
        XCTAssertEqual(ContainerUnavailable.failed(command: "docker stats", status: 125, message: "unknown flag: --no-stream").reason,
                       "docker stats failed with exit status 125: unknown flag: --no-stream")
    }

    func testUnparsableOutputLeavesNoBreakdown() async throws {
        let stub = try makeStub("""
        [ "$1" = ps ] && exit 0
        echo 'Error: template parsing error'
        """)

        let report = await cli([stub]).report()

        XCTAssertEqual(report.outcome, .unavailable(.unparsableOutput(command: "docker stats")))
    }

    func testOnlyAnExecutableFileAtACandidatePathIsRun() async throws {
        let missing = folder.appendingPathComponent("missing/docker").path
        let notExecutable = folder.appendingPathComponent("plain").path
        try "echo nope".write(toFile: notExecutable, atomically: true, encoding: .utf8)
        let directory = folder.appendingPathComponent("dir").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stub = try makeStub("echo \"$1\" >> '\(runLog)'")

        let none = await cli([missing, notExecutable, directory]).report()
        XCTAssertEqual(none.outcome, .unavailable(.cliNotFound))
        XCTAssertNil(none.executable)
        XCTAssertNil(none.context)
        XCTAssertEqual(cli([missing, notExecutable, directory, stub]).executable(), stub, "the first executable candidate is used")
        XCTAssertEqual(DockerCLI.candidatePaths(home: "/Users/me"), [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Users/me/.orbstack/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ])
    }

    func testTheRunnerReportsALaunchFailureAndStopsRunawayOutput() async throws {
        let notExecutable = folder.appendingPathComponent("plain").path
        try "echo nope".write(toFile: notExecutable, atomically: true, encoding: .utf8)
        let chatty = try makeStub("echo $$ > '\(pidFile)'\nexec yes", name: "chatty")

        let launch = await ProcessCommandRunner().run(notExecutable, arguments: [], environment: [:], timeout: .seconds(5))
        let flood = await ProcessCommandRunner(outputLimit: 64 << 10).run(chatty, arguments: [], environment: [:], timeout: .seconds(5))

        guard case .failure(.launchFailed) = launch else { return XCTFail("\(launch)") }
        XCTAssertEqual(flood, .failure(.outputTooLarge))
        try await assertExits(try stubPID(), "the command is stopped past the cap")
    }

    func testATimedOutCommandIsStopped() async throws {
        let stub = try await warmedStub("echo $$ > '\(pidFile)'\nexec sleep 30")

        let result = await ProcessCommandRunner().run(stub, arguments: [], environment: [:], timeout: .milliseconds(500))

        XCTAssertEqual(result, .failure(.timedOut))
        try await assertExits(try stubPID(), "the command is stopped past the timeout")
    }

    func testACommandThatIgnoresSIGTERMIsKilledAfterATimeoutOrACancellation() async throws {
        // An ignored signal stays ignored across exec, so `sleep` survives SIGTERM.
        let stub = try await warmedStub("trap '' TERM\necho $$ > '\(pidFile)'\nexec sleep 30")

        let timedOut = await ProcessCommandRunner().run(stub, arguments: [], environment: [:], timeout: .milliseconds(500))
        XCTAssertEqual(timedOut, .failure(.timedOut))
        let first = try stubPID()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(kill(first, 0), 0, "SIGTERM alone does not stop it")
        try await assertExits(first, "SIGKILL stops it after a timeout", within: .seconds(2))

        try FileManager.default.removeItem(atPath: pidFile)
        let run = Task { await ProcessCommandRunner().run(stub, arguments: [], environment: [:], timeout: .seconds(30)) }
        let second = try await waitForStubPID()
        run.cancel()
        let cancelled = await run.value
        XCTAssertEqual(cancelled, .failure(.cancelled))
        try await assertExits(second, "SIGKILL stops it after a cancellation", within: .seconds(2))
    }

    func testShuttingDownKillsARunningCommandThatIgnoresSIGTERMBeforeItReturnsAndStartsNoMore() async throws {
        let stub = try await warmedStub("trap '' TERM\necho $$ > '\(pidFile)'\nexec sleep 30")
        let registry = CommandRegistry()
        let run = Task { await ProcessCommandRunner(registry: registry).run(stub, arguments: [], environment: [:], timeout: .seconds(30)) }
        let pid = try await waitForStubPID()

        registry.shutDown()

        let killed = await run.value
        XCTAssertEqual(killed, .failure(.cancelled))
        // Well inside the second a cancellation waits before `SIGKILL`, which would not fire in a quitting app.
        try await assertExits(pid, "the command is killed at once", within: .milliseconds(500))
        try FileManager.default.removeItem(atPath: pidFile)
        let after = await ProcessCommandRunner(registry: registry).run(stub, arguments: [], environment: [:], timeout: .seconds(5))
        XCTAssertEqual(after, .failure(.cancelled), "no command starts after the shutdown")
        let other = await ProcessCommandRunner(registry: CommandRegistry()).run(stub, arguments: ["warm"], environment: [:], timeout: .seconds(5))
        XCTAssertEqual(try other.get().status, 0, "another registry's runner is unaffected")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile), "the refused command was never started")
    }

    func testAShutdownBeforeACommandLaunchesKeepsItFromLaunching() async throws {
        let stub = try await warmedStub("trap '' TERM\necho $$ > '\(pidFile)'\nexec sleep 30")
        let registry = CommandRegistry()
        // The shutdown lands after the run registered and before it launched.
        let hooks = LaunchHooks(beforeLaunch: { registry.shutDown() })

        let result = await ProcessCommandRunner(registry: registry, hooks: hooks).run(stub, arguments: [], environment: [:], timeout: .seconds(30))

        XCTAssertEqual(result, .failure(.cancelled))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile), "the command never launched")
    }

    func testAShutdownRightAfterTheLaunchKillsTheCommandBeforeItReturnsWithoutTheRunnersThread() async throws {
        let stub = try await warmedStub("trap '' TERM\necho $$ > '\(pidFile)'\nexec sleep 30")
        let registry = CommandRegistry()
        // The runner's thread stays held just after the launch until the end, as in an app that exits first.
        let held = DispatchSemaphore(value: 0)
        let hooks = LaunchHooks(afterLaunch: { held.wait() })
        defer { held.signal() }
        let run = Task { await ProcessCommandRunner(registry: registry, hooks: hooks).run(stub, arguments: [], environment: [:], timeout: .seconds(30)) }
        let pid = try await waitForStubPID()

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                registry.shutDown()
                done.resume()
            }
        }

        // Well inside the second a cancellation waits before `SIGKILL`.
        try await assertExits(pid, "the command is killed by the shutdown itself", within: .milliseconds(500))
        held.signal()
        let result = await run.value
        XCTAssertEqual(result, .failure(.cancelled))
    }

    func testCancellingTheTaskStopsTheCommandAndAnAlreadyCancelledTaskStartsNone() async throws {
        let stub = try await warmedStub("echo $$ > '\(pidFile)'\nexec sleep 30")

        let run = Task { await ProcessCommandRunner().run(stub, arguments: [], environment: [:], timeout: .seconds(30)) }
        let pid = try await waitForStubPID()
        run.cancel()

        let cancelled = await run.value
        XCTAssertEqual(cancelled, .failure(.cancelled))
        try await assertExits(pid, "a cancelled run leaves no child")

        try FileManager.default.removeItem(atPath: pidFile)
        let never = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ProcessCommandRunner().run(stub, arguments: [], environment: [:], timeout: .seconds(30))
        }
        let notStarted = await never.value
        XCTAssertEqual(notStarted, .failure(.cancelled))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile), "nothing was started")
    }

    // MARK: Current context

    func testARemoteContextIsRefusedWithoutRunningTheCLI() async throws {
        try writeContext("prod", host: "ssh://deploy@203.0.113.9")
        let stub = try makeStub("echo \"$1\" >> '\(runLog)'")

        let report = await cli([stub]).report()

        XCTAssertEqual(report.outcome, .unavailable(.remoteContext(name: "prod", host: "ssh://deploy@203.0.113.9")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runLog), "the CLI never ran")
    }

    func testASocketNoRuntimeOwnsIsNotAskedEvenWithOneRuntimeRunning() async throws {
        let podman = home + "/.local/share/containers/podman/machine/podman.sock"
        try FileManager.default.createDirectory(atPath: (podman as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: podman, contents: nil)
        try writeContext("podman-machine-default", host: "unix://\(podman)")
        let stub = try makeStub("echo \"$1\" >> '\(runLog)'\necho '{\"ID\":\"3f2a9c1b7d4e\",\"Names\":\"db\"}'")
        let poller = ContainerPoller(cli: cli([stub]))

        let refreshed = await poller.refresh(cadence: .mainWindowVisible, runningRuntimes: [.orbStack])
        let report = try XCTUnwrap(refreshed)

        let reason = ContainerUnavailable.contextNotRecognized(name: "podman-machine-default", host: "unix://\(podman)")
        XCTAssertEqual(report.outcome, .unavailable(reason))
        XCTAssertEqual(report.status(of: .orbStack), .unavailable(reason), "OrbStack alone is not shown Podman's containers")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runLog), "the CLI never ran")
    }

    func testALocalContextNamesTheRuntimeItsSocketBelongsTo() throws {
        let socketFolder = folder.appendingPathComponent("home/.orbstack/run")
        try FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: true)
        let socket = socketFolder.appendingPathComponent("docker.sock").path
        FileManager.default.createFile(atPath: socket, contents: nil)
        let link = folder.appendingPathComponent("docker.sock").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: socket)
        try writeContext("custom", host: "unix://\(link)")

        let context = try DockerContextReader(home: home).current().get()

        XCTAssertEqual(context, DockerContext(name: "custom", host: "unix://\(link)", endpoint: "unix://" + resolved(socket), runtime: .orbStack),
                       "a symlinked socket is followed, and the endpoint is where it leads")
    }

    func testAnUnreadableContextGivesItsReason() throws {
        try FileManager.default.createDirectory(atPath: home + "/.docker", withIntermediateDirectories: true)
        try "{\"currentContext\":\"gone\"}".write(toFile: home + "/.docker/config.json", atomically: true, encoding: .utf8)
        guard case let .failure(.contextUnreadable(path, message)) = DockerContextReader(home: home).current() else {
            return XCTFail("a context without a meta file is unreadable")
        }
        XCTAssertTrue(path.hasSuffix("/meta.json"))
        XCTAssertEqual(message, "not found")

        // The CLI reads an empty config as no settings: the default context.
        let none = "unix://" + folder.appendingPathComponent("none.sock").path
        for empty in ["", " \n\t"] {
            try empty.write(toFile: home + "/.docker/config.json", atomically: true, encoding: .utf8)
            XCTAssertEqual(try DockerContextReader(home: home, defaultHost: none).current().get().name, "default", "config \(empty.debugDescription)")
        }

        try "not json".write(toFile: home + "/.docker/config.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(DockerContextReader(home: home).current(),
                       .failure(.contextUnreadable(path: home + "/.docker/config.json", message: "not a JSON object")))

        try FileManager.default.removeItem(atPath: home + "/.docker/config.json")
        XCTAssertEqual(mkfifo(home + "/.docker/config.json", 0o600), 0)
        XCTAssertEqual(DockerContextReader(home: home).current(),
                       .failure(.contextUnreadable(path: home + "/.docker/config.json", message: "not a regular file")),
                       "a FIFO in place of the config does not block")
    }

    func testAReportCoversOnlyTheRuntimeItsContextReaches() {
        let breakdown = ContainerBreakdown(listing: DockerOutput.listing(""), stats: DockerOutput.stats(""))
        let orb = DockerContext(name: "orbstack", host: "unix:///Users/me/.orbstack/run/docker.sock",
                                endpoint: "unix:///Users/me/.orbstack/run/docker.sock", runtime: .orbStack)
        let custom = DockerContext(name: "custom", host: "unix:///tmp/docker.sock", endpoint: "unix:///private/tmp/docker.sock", runtime: nil)
        let measured = ContainerReport(observedAt: Date(), executable: "/x", context: orb, outcome: .breakdown(breakdown))

        XCTAssertEqual(measured.status(of: .orbStack), .measured(breakdown))
        XCTAssertEqual(measured.status(of: .dockerDesktop),
                       .otherContext(name: "orbstack", runtime: .orbStack))
        let unknown = ContainerReport(observedAt: Date(), executable: "/x", context: custom, outcome: .breakdown(breakdown))
        XCTAssertEqual(unknown.status(of: .colima), .unavailable(.contextNotRecognized(name: "custom", host: "unix:///tmp/docker.sock")),
                       "a socket no runtime owns is never given to the only one running")
        let missing = ContainerReport(observedAt: Date(), outcome: .unavailable(.cliNotFound))
        XCTAssertEqual(missing.status(of: .colima), .unavailable(.cliNotFound))
    }

    // MARK: Poller

    func testThePollerRunsAtMostOnceEveryTenSeconds() async throws {
        let stub = try makeStub("echo \"$1\" >> '\(runLog)'")
        let poller = ContainerPoller(cli: cli([stub]))
        let start = ContinuousClock.now

        let first = await poller.refresh(cadence: .mainWindowVisible, runningRuntimes: [.colima], now: start)
        let early = await poller.refresh(cadence: .mainWindowVisible, runningRuntimes: [.colima], now: start + .seconds(9.9))
        XCTAssertNotNil(first)
        XCTAssertNil(early)
        XCTAssertEqual(try runs(), ["ps", "stats"], "no second run within 10 seconds")

        let later = await poller.refresh(cadence: .mainWindowVisible, runningRuntimes: [.colima], now: start + .seconds(10))
        XCTAssertNotNil(later)
        XCTAssertEqual(try runs(), ["ps", "stats", "ps", "stats"])
        XCTAssertEqual(ContainerPoller.minimumInterval, .seconds(10))
    }

    func testThePollerNeverRunsForTheMenuBarAloneOrWithoutAVM() async throws {
        let stub = try makeStub("echo \"$1\" >> '\(runLog)'")
        let poller = ContainerPoller(cli: cli([stub]))

        let menuBar = await poller.refresh(cadence: .menuBarOnly, runningRuntimes: [.dockerDesktop], now: .now)
        let noVM = await poller.refresh(cadence: .mainWindowVisible, runningRuntimes: [], now: .now)

        XCTAssertNil(menuBar)
        XCTAssertNil(noVM)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runLog))
    }

    func testHidingTheWindowDuringASlowListingStopsItAndStartsNoStats() async throws {
        let stub = try await warmedStub("""
        echo "$1" >> '\(runLog)'
        echo $$ > '\(pidFile)'
        exec sleep 30
        """)
        let poller = ContainerPoller(cli: cli([stub], timeout: .seconds(30)))

        let refresh = Task { await poller.refresh(cadence: .mainWindowVisible, runningRuntimes: [.dockerDesktop]) }
        let pid = try await waitForStubPID()
        refresh.cancel()

        let report = await refresh.value
        XCTAssertNil(report, "a cancelled refresh gives no report")
        try await assertExits(pid, "docker ps is stopped")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try runs(), ["ps"], "stats never starts")
    }

    func testThePollerNeverRunsTwiceAtOnce() async throws {
        let stub = try makeStub("""
        echo "$1" >> '\(runLog)'
        sleep 0.5
        """)
        let poller = ContainerPoller(cli: cli([stub]))
        let start = ContinuousClock.now

        async let first = poller.refresh(cadence: .mainWindowVisible, runningRuntimes: [.orbStack], now: start)
        let deadline = ContinuousClock.now + .seconds(10)
        while (try? runs()) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let overlapping = await poller.refresh(cadence: .mainWindowVisible, runningRuntimes: [.orbStack], now: start + .seconds(20))

        XCTAssertNil(overlapping, "a run is in progress")
        let finished = await first
        XCTAssertNotNil(finished)
        XCTAssertEqual(try runs(), ["ps", "stats"])
    }

    // MARK: Helpers

    private func cli(_ candidates: [String], timeout: Duration = .seconds(5), defaultHost: String = DockerCLI.defaultHost) -> DockerCLI {
        DockerCLI(home: home, candidates: candidates, timeout: timeout, defaultHost: defaultHost)
    }

    /// An executable `/bin/sh` script standing in for `docker`. It logs and drops the `--host` the CLI pins, so
    /// `$1` is the command.
    private func makeStub(_ body: String, name: String = "docker") throws -> String {
        let path = folder.appendingPathComponent(name).path
        let host = "if [ \"$1\" = --host ]; then echo \"$2\" >> '\(hostLog)'; shift 2; fi"
        try "#!/bin/sh\n\(host)\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(path, 0o755), 0)
        return path
    }

    /// A stub run once already, so the first run's malware scan cannot hold it past a short timeout.
    private func warmedStub(_ body: String) async throws -> String {
        let stub = try makeStub("[ \"$1\" = warm ] && exit 0\n\(body)")
        let warm = await ProcessCommandRunner().run(stub, arguments: ["warm"], environment: [:], timeout: .seconds(30))
        XCTAssertEqual(try warm.get().status, 0)
        return stub
    }

    private func stubPID() throws -> pid_t {
        let text = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text))
    }

    private func waitForStubPID() async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: pidFile), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The script writes its PID, then replaces itself with the command.
        try await Task.sleep(for: .milliseconds(100))
        return try stubPID()
    }

    /// Waits for the process to exit and be reaped (`SIGTERM`, then `SIGKILL` a second later).
    private func assertExits(_ pid: pid_t, _ message: String, within limit: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + limit
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(kill(pid, 0), 0, message)
        XCTAssertEqual(errno, ESRCH, message)
    }

    private func hosts() throws -> [String] {
        try String(contentsOfFile: hostLog, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// The real path, as the CLI is pinned to it.
    private func resolved(_ path: String) -> String {
        guard let pointer = realpath(path, nil) else { return path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// A file standing in for a runtime's socket: the stub never connects to it.
    private func makeSocket(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
    }

    private func runs() throws -> [String] {
        try String(contentsOfFile: runLog, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Makes `name` the current context, with its endpoint where the CLI keeps it.
    private func writeContext(_ name: String, host: String) throws {
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let meta = home + "/.docker/contexts/meta/\(digest)"
        try FileManager.default.createDirectory(atPath: meta, withIntermediateDirectories: true)
        try "{\"currentContext\":\"\(name)\"}".write(toFile: home + "/.docker/config.json", atomically: true, encoding: .utf8)
        try "{\"Name\":\"\(name)\",\"Metadata\":{},\"Endpoints\":{\"docker\":{\"Host\":\"\(host)\",\"SkipTLSVerify\":false}}}"
            .write(toFile: meta + "/meta.json", atomically: true, encoding: .utf8)
    }
}
