import Foundation
@testable import SubsetCore
import XCTest

/// The Command Line section: finding `subset` through a shell (a fake one, except where the login shell itself is run),
/// and the examples for the commands installed apps bundle, from the feed's `helpers`.
final class CommandLineTests: XCTestCase {
    // MARK: Detection

    func testFoundRunsTheVersionCommandForFiveSecondsAndShowsTheVersion() async {
        let shell = FakeShell(.output(ShellOutput(status: 0, stdout: framed("0.2.0\n"))))
        let status = await detector(shell).detect()
        XCTAssertEqual(status, .installed(version: "0.2.0"))
        XCTAssertEqual(shell.calls.map(\.command), [
            "set +m; echo subset-check-test-check-start; /usr/bin/env subset --version && echo subset-check-test-check-end",
        ])
        XCTAssertEqual(shell.calls.map(\.timeout), [5])
    }

    /// Startup files print before the command, and logout files or an EXIT trap after it, changing the shell's status.
    func testFoundWhateverTheShellPrintsAroundTheCommandOrHowItExits() async {
        let outputs = [
            ShellOutput(status: 0, stdout: "Welcome back\n" + framed("  0.2.1-beta.1  \n")),
            ShellOutput(status: 3, stdout: "Welcome back\n" + framed("0.2.0\n") + "bye from .zlogout\n"),
            ShellOutput(status: nil, stdout: framed("0.2.0\n") + "a startup file's job held the output\n"),
            ShellOutput(status: 0, stdout: framed("0.2.0")),  // no newline after the version
        ]
        for output in outputs {
            let status = await detector(FakeShell(.output(output))).detect()
            XCTAssertNotEqual(status, .notInstalled, output.stdout)
        }
    }

    func testMissingOrUnusableIsNotInstalled() async {
        let start = SubsetCommandDetector.startMarker("test-check")
        let end = SubsetCommandDetector.endMarker("test-check")
        let outputs: [ShellOutput?] = [
            ShellOutput(status: 127, stdout: "\(start)\n"),  // env: subset: No such file or directory: no end marker
            ShellOutput(status: 0, stdout: "\(start)\n0.2.0\n"),  // subset failed, then a logout file exited 0
            ShellOutput(status: 0, stdout: "0.2.0\n"),
            ShellOutput(status: 0, stdout: "\(end)\n0.2.0\n\(start)\n"),
            ShellOutput(status: 0, stdout: framed("0.2.0\n", token: "other-check")),
            ShellOutput(status: 0, stdout: framed("")),
            ShellOutput(status: 0, stdout: framed("Welcome\n0.2.0\n")),
            ShellOutput(status: 0, stdout: framed("zsh: command not found: subset\n")),
            ShellOutput(status: 0, stdout: framed("0.2.0\u{1b}[31m\n")),
            ShellOutput(status: 0, stdout: framed("0.2.0-" + String(repeating: "a", count: 60) + "\n")),
            nil,  // the shell could not be started
        ]
        for output in outputs {
            let status = await detector(FakeShell(output.map(FakeShell.Behavior.output) ?? .unavailable)).detect()
            XCTAssertEqual(status, .notInstalled, "\(String(describing: output))")
        }
    }

    func testTimeoutIsNotInstalledAndStopsTheShell() async throws {
        let shell = FakeShell(.hangUntilCancelled(stopping: 0))
        let started = Date()
        let status = await detector(shell, timeLimit: 0.2).detect()
        XCTAssertEqual(status, .notInstalled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        for _ in 0..<50 where !shell.wasCancelled { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(shell.wasCancelled, "the shell was left running past the time limit")
    }

    /// An interactive shell ignores SIGTERM, so stopping it can take longer than the limit; the answer does not wait.
    func testTimeoutDoesNotWaitForAShellThatIsSlowToStop() async {
        let shell = FakeShell(.ignoreCancelThenAnswer(seconds: 3, ShellOutput(status: 0, stdout: framed("0.2.0\n"))))
        let started = Date()
        let status = await detector(shell, timeLimit: 0.2).detect()
        XCTAssertEqual(status, .notInstalled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testACancelledCheckEndsAtOnceAsNotInstalled() async {
        let shell = FakeShell(.ignoreCancelThenAnswer(seconds: 3, ShellOutput(status: 0, stdout: framed("0.2.0\n"))))
        let started = Date()
        let checker = detector(shell)
        let task = Task { await checker.detect() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let status = await task.value
        XCTAssertEqual(status, .notInstalled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTheLoginShellRunsTheCommandLineInAnInteractiveShell() async throws {
        let shell = LoginShell(path: "/bin/sh")
        let foundOutput = await shell.run("case $- in *i*) echo 1.2.3; exit 0;; esac; exit 9", timeout: 5)
        let found = try XCTUnwrap(foundOutput)
        XCTAssertEqual(found.status, 0, "not run as an interactive shell")
        XCTAssertEqual(found.stdout.split(whereSeparator: \.isNewline).last, "1.2.3")
        let missingOutput = await shell.run("/usr/bin/env subset-command-that-does-not-exist --version", timeout: 5)
        let missing = try XCTUnwrap(missingOutput)
        XCTAssertEqual(missing.status, 127)
        let slowOutput = await shell.run("sleep 30", timeout: 0.3)
        let slow = try XCTUnwrap(slowOutput)
        XCTAssertNil(slow.status)
    }

    /// A real /bin/sh that prints before the command and, from an EXIT trap, after it and exits 3, with a `subset` on
    /// its PATH that prints a version and with none.
    func testARealShellPrintingAroundTheCommandStillFindsTheVersion() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-command-\(UUID().uuidString)")
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func script(_ name: String, in directory: URL, _ body: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        _ = try script("subset", in: bin, "echo 0.2.0\n")
        // Called as `<shell> -ilc <line>`, like a login shell: $1 is -ilc and $2 the line.
        let found = try script("found-shell", in: folder, """
            echo 'Welcome back'
            trap 'echo "bye from .zlogout"; exit 3' EXIT
            PATH='\(bin.path)':/usr/bin:/bin; export PATH
            eval "$2"

            """)
        let missing = try script("missing-shell", in: folder, """
            trap 'echo "bye from .zlogout"; exit 0' EXIT
            PATH=/usr/bin:/bin; export PATH
            eval "$2"

            """)
        let foundStatus = await SubsetCommandDetector(shell: LoginShell(path: found)).detect()
        XCTAssertEqual(foundStatus, .installed(version: "0.2.0"))
        let missingStatus = await SubsetCommandDetector(shell: LoginShell(path: missing)).detect()
        XCTAssertEqual(missingStatus, .notInstalled)
    }

    /// A stalled `subset` is stopped with its login shell when the check times out and when the model stops, under
    /// zsh, bash and sh run for real with no terminal (as `ToolRunner` runs them): bash and sh give a foreground command
    /// a process group of its own unless job control is off.
    @MainActor
    func testATimedOutOrQuitCheckStopsTheStalledSubsetCommandUnderEachLoginShell() async throws {
        for shellPath in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: shellPath), "\(shellPath) is missing")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-command-\(UUID().uuidString)")
            let bin = folder.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let pidFile = folder.appendingPathComponent("pid")
            let fake = bin.appendingPathComponent("subset")
            // `exec` makes the recorded pid the long sleep's own.
            try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 120\n".write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            setenv("PATH", "\(bin.path):\(oldPath)", 1)
            var pid: pid_t = 0
            defer {
                setenv("PATH", oldPath, 1)
                if pid > 0 { kill(pid, SIGKILL) }
                try? FileManager.default.removeItem(at: folder)
            }
            let model = CommandLineModel(detector: SubsetCommandDetector(shell: LoginShell(path: shellPath), timeLimit: 1.5))
            await model.check()
            let recorded = (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            pid = try XCTUnwrap(recorded.flatMap { pid_t($0) }, "\(shellPath): the fake subset never ran")
            XCTAssertEqual(model.status, .notInstalled, shellPath)
            await model.stop()
            XCTAssertFalse(model.hasRunningShell, shellPath)
            var gone = false
            for _ in 0..<50 where !gone {
                gone = kill(pid, 0) != 0
                if !gone { try await Task.sleep(nanoseconds: 40_000_000) }
            }
            XCTAssertTrue(gone, "\(shellPath): the stalled subset command is still running after the check was stopped")
        }
    }

    func testTheUsersShellIsAnAbsoluteExecutablePathOrZsh() {
        let executable: (String) -> Bool = { $0 != "/missing/fish" }
        XCTAssertEqual(LoginShell.resolve(account: "/bin/bash", environment: "/bin/zsh", isExecutable: executable), "/bin/bash")
        XCTAssertEqual(LoginShell.resolve(account: "/missing/fish", environment: "/bin/ksh", isExecutable: executable), "/bin/ksh")
        XCTAssertEqual(LoginShell.resolve(account: "bash", environment: "zsh", isExecutable: executable), "/bin/zsh")
        XCTAssertEqual(LoginShell.resolve(account: nil, environment: nil, isExecutable: executable), "/bin/zsh")
    }

    @MainActor
    func testTheModelShowsCheckingThenTheResultAndRunsOneCheckAtATime() async throws {
        let shell = FakeShell(.ignoreCancelThenAnswer(seconds: 0.3, ShellOutput(status: 0, stdout: framed("0.2.0\n"))))
        let model = CommandLineModel(detector: detector(shell))
        XCTAssertEqual(model.status, .checking)
        let first = Task { await model.check() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(model.isChecking)
        await model.check()
        await first.value
        XCTAssertEqual(model.status, .installed(version: "0.2.0"))
        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(shell.calls.count, 1)

        let missing = CommandLineModel(detector: detector(FakeShell(.output(ShellOutput(status: 127, stdout: "")))))
        await missing.check()
        XCTAssertEqual(missing.status, .notInstalled)
    }

    /// Quitting stops a shell that the time limit already gave up on (its check shows "not installed" while it is still
    /// being stopped) and waits until it has ended.
    @MainActor
    func testStoppingTheModelWaitsForAShellGivenUpAtTheTimeLimit() async throws {
        let shell = FakeShell(.hangUntilCancelled(stopping: 0.5))
        let model = CommandLineModel(detector: detector(shell, timeLimit: 0.1))
        await model.check()
        XCTAssertEqual(model.status, .notInstalled)
        XCTAssertTrue(model.hasRunningShell)
        XCTAssertFalse(shell.hasEnded)
        await model.stop()
        XCTAssertTrue(shell.hasEnded, "stop returned before the shell had ended")
        XCTAssertFalse(model.hasRunningShell)
    }

    /// Quitting during a check stops its shell, waits for it, shows "not installed" and starts no new check.
    @MainActor
    func testStoppingTheModelStopsARunningCheckAndStartsNoOther() async throws {
        let shell = FakeShell(.hangUntilCancelled(stopping: 0.3))
        let model = CommandLineModel(detector: detector(shell, timeLimit: 30))
        let check = Task { await model.check() }
        for _ in 0..<50 where shell.calls.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(model.isChecking)
        let started = Date()
        await model.stop()
        XCTAssertTrue(shell.wasCancelled)
        XCTAssertTrue(shell.hasEnded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        await check.value
        XCTAssertEqual(model.status, .notInstalled)
        await model.check()
        XCTAssertEqual(shell.calls.count, 1)
        XCTAssertFalse(model.isChecking)
    }

    /// A shell that never ends does not hold quitting past the limit.
    @MainActor
    func testStoppingTheModelWaitsNoLongerThanItsLimit() async throws {
        let shell = FakeShell(.ignoreCancelThenAnswer(seconds: 5, ShellOutput(status: 0, stdout: "")))
        let model = CommandLineModel(detector: detector(shell, timeLimit: 0.1))
        await model.check()
        let started = Date()
        await model.stop(within: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(model.hasRunningShell)
    }

    // MARK: Examples

    func testExamplesComeFromTheHelpersOfInstalledAppsInFeedOrder() throws {
        let apps = [
            app("system", "Subset System", helpers: [helper("system")]),
            app("breaks", "Breaks", helpers: []),
            app("timer", "Timer", helpers: [helper("timer", kind: "node")]),
            app("minutes", "Minutes", helpers: [helper("minutes", kind: "node")]),
            app("future", "Future", helpers: [helper("future"), helper("future-two")]),
        ]
        let copy = InstalledCopy(path: "/Applications/X.app", folder: "/Applications", version: "0.1.0", build: "1", channel: nil)
        let installed = ["timer": [copy], "breaks": [copy], "future": [copy], "system": [], "gone": [copy]]
        let examples = HelperExamples.examples(apps: apps, installed: installed)
        XCTAssertEqual(examples.map(\.example), [
            "subset timer list", "subset future --help", "subset future-two --help",
        ])
        XCTAssertEqual(examples.map(\.appName), ["Timer", "Future", "Future"])
        XCTAssertEqual(examples.map(\.command), ["timer", "future", "future-two"])
        XCTAssertEqual(examples[0].guide.absoluteString, "https://github.com/21nCo/subset/blob/dev/packages/timer-cli/README.md#agent-skill")
        XCTAssertEqual(
            examples[1].guide.absoluteString,
            "https://github.com/21nCo/subset/blob/dev/packages/subset-dev/README.md#commands-bundled-in-mac-apps"
        )
        XCTAssertEqual(HelperExamples.examples(apps: apps, installed: [:]), [])
        XCTAssertEqual(HelperExamples.setupCommand, "npm i -g subset.dev")
    }

    /// Every command an app declares in its `macos-release.json` has its own example, and every guide is a heading of
    /// its README in this checkout, so neither drifts from the apps or the docs.
    func testEveryDeclaredHelperHasAnExampleAndEveryGuideIsAREADMEHeading() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
        let native = root.appendingPathComponent("native")
        var declared: Set<String> = []
        for folder in try FileManager.default.contentsOfDirectory(atPath: native.path) {
            let manifest = native.appendingPathComponent(folder).appendingPathComponent("macos-release.json")
            guard let data = FileManager.default.contents(atPath: manifest.path) else { continue }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for helper in json["helpers"] as? [[String: Any]] ?? [] { declared.insert(try XCTUnwrap(helper["command"] as? String)) }
        }
        XCTAssertFalse(declared.isEmpty)
        XCTAssertEqual(declared, Set(HelperExamples.known.keys))

        for guide in HelperExamples.known.values.map(\.guide) + [HelperExamples.fallbackGuide] {
            let parts = guide.split(separator: "#").map(String.init)
            let readme = try String(contentsOf: root.appendingPathComponent(parts[0]), encoding: .utf8)
            let anchors = readme.split(separator: "\n").filter { $0.hasPrefix("#") }.map { heading in
                heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                    .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
                    .replacingOccurrences(of: " ", with: "-")
            }
            XCTAssertTrue(anchors.contains(parts[1]), "\(guide) is not a heading of \(parts[0])")
        }
    }

    /// A detector whose output markers are named after `test-check`.
    private func detector(_ shell: FakeShell, timeLimit: TimeInterval = SubsetCommandDetector.timeLimit) -> SubsetCommandDetector {
        SubsetCommandDetector(shell: shell, timeLimit: timeLimit, token: { "test-check" })
    }

    /// What the shell line prints when `subset --version` prints `output` and exits 0.
    private func framed(_ output: String, token: String = "test-check") -> String {
        "\(SubsetCommandDetector.startMarker(token))\n\(output)\(SubsetCommandDetector.endMarker(token))\n"
    }

    private func app(_ id: String, _ name: String, helpers: [CatalogHelper]) -> CatalogApp {
        CatalogApp(
            id: id, name: name, summary: "\(name) summary", appName: name, bundleID: "dev.subset.\(id)", helpers: helpers,
            live: nil, beta: nil
        )
    }

    private func helper(_ command: String, kind: String = "native") -> CatalogHelper {
        CatalogHelper(command: command, path: kind == "node" ? "Contents/Resources/\(command)-cli/dist/cli.mjs" : "Contents/Helpers/\(command)", kind: kind)
    }
}

/// A shell that answers as told and records what it was asked to run, whether it was cancelled and whether it ended.
private final class FakeShell: CommandShell, @unchecked Sendable {
    enum Behavior {
        case output(ShellOutput)
        case unavailable
        /// Runs until cancelled, then takes `stopping` seconds to end, as a shell's group being stopped does.
        case hangUntilCancelled(stopping: TimeInterval)
        /// Answers after `seconds` whether or not it is cancelled meanwhile.
        case ignoreCancelThenAnswer(seconds: TimeInterval, ShellOutput)
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var recorded: [(command: String, timeout: TimeInterval)] = []
    private var cancelled = false
    private var ended = false

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var calls: [(command: String, timeout: TimeInterval)] { lock.withLock { recorded } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var hasEnded: Bool { lock.withLock { ended } }

    func run(_ command: String, timeout: TimeInterval) async -> ShellOutput? {
        lock.withLock { recorded.append((command, timeout)) }
        defer { lock.withLock { ended = true } }
        switch behavior {
        case .output(let output):
            return output
        case .unavailable:
            return nil
        case .hangUntilCancelled(let stopping):
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if Task.isCancelled { lock.withLock { cancelled = true } }
            await Self.pause(stopping)
            return nil
        case let .ignoreCancelThenAnswer(seconds, output):
            await Self.pause(seconds)
            return output
        }
    }

    /// Waits even when cancelled.
    private static func pause(_ seconds: TimeInterval) async {
        await Task.detached { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }.value
    }
}
