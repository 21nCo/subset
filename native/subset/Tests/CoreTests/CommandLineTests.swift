import Foundation
@testable import SubsetCore
import XCTest

/// The Command Line section: finding `subset` through a shell (a fake one, except where the login shell itself is run),
/// and the examples for the commands installed apps bundle, from the feed's `helpers`.
final class CommandLineTests: XCTestCase {
    // MARK: Detection

    func testFoundRunsTheVersionCommandWithTheLoginShellsEnvironmentAndShowsTheVersion() async {
        let environment = LoginEnvironment(variables: ["PATH": "/login/bin:/usr/bin"], directory: "/login/home")
        let shell = FakeShell(login: .answer(environment), version: .answer(ShellOutput(status: 0, stdout: "0.2.0\n")))
        let status = await detector(shell).detect()
        XCTAssertEqual(status, .installed(version: "0.2.0"))
        XCTAssertEqual(shell.pathTimeouts, [5])
        XCTAssertEqual(shell.runs.map(\.command), [["/usr/bin/env", "subset", "--version"]])
        XCTAssertEqual(shell.runs.first?.environment, ["PATH": "/login/bin:/usr/bin"])
        XCTAssertEqual(shell.runs.first?.directory, "/login/home")
        XCTAssertEqual(shell.runs.first?.timeout ?? 0, 5, accuracy: 0.5, "the version command gets what is left of the 5 seconds")
    }

    /// The shell's EXIT trap or logout files still run after it told its PATH; the answer does not wait for them.
    @MainActor
    func testFoundAsSoonAsTheVersionCommandAnswersWhileTheShellStillRuns() async {
        let shell = FakeShell(login: .answer(login("/login/bin"), thenRun: 1), version: .answer(ShellOutput(status: 0, stdout: "0.2.0\n")))
        let model = CommandLineModel(detector: detector(shell))
        let started = Date()
        await model.check()
        XCTAssertEqual(model.status, .installed(version: "0.2.0"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        XCTAssertTrue(model.hasRunningShell)
        await model.stop()
        XCTAssertTrue(shell.hasEnded("shell"))
        XCTAssertFalse(model.hasRunningShell)
    }

    func testOnlyAVersionPrintedByASuccessfulVersionCommandIsInstalled() async {
        let found = ["  0.2.1-beta.1  \n": "0.2.1-beta.1", "0.2.0": "0.2.0"]
        for (stdout, version) in found {
            let status = await detector(FakeShell(login: .answer(login("/bin")), version: .answer(ShellOutput(status: 0, stdout: stdout)))).detect()
            XCTAssertEqual(status, .installed(version: version), stdout)
        }
        let outputs: [ShellOutput?] = [
            ShellOutput(status: 127, stdout: ""),  // env: subset: No such file or directory
            ShellOutput(status: 1, stdout: "0.2.0\n"),
            ShellOutput(status: nil, stdout: "0.2.0\n"),  // stopped
            ShellOutput(status: 0, stdout: ""),
            ShellOutput(status: 0, stdout: "Welcome\n0.2.0\n"),
            ShellOutput(status: 0, stdout: "0.2.0\u{1b}[31m\n"),
            ShellOutput(status: 0, stdout: "0.2.0-" + String(repeating: "a", count: 60) + "\n"),
            nil,  // could not be started
        ]
        for output in outputs {
            let status = await detector(FakeShell(login: .answer(login("/bin")), version: .answer(output))).detect()
            XCTAssertEqual(status, .notInstalled, "\(String(describing: output))")
        }
        // The shell ended, or could not be started, without telling its environment: no version command runs.
        let noPath = FakeShell(login: .answer(nil), version: .answer(ShellOutput(status: 0, stdout: "0.2.0\n")))
        let status = await detector(noPath).detect()
        XCTAssertEqual(status, .notInstalled)
        XCTAssertTrue(noPath.runs.isEmpty)
    }

    func testTimeoutIsNotInstalledAndStopsTheShellOrTheVersionCommand() async throws {
        let silentShell = FakeShell(login: .hangUntilCancelled(stopping: 0), version: .answer(ShellOutput(status: 0, stdout: "0.2.0\n")))
        let stalledVersion = FakeShell(login: .answer(login("/bin")), version: .hangUntilCancelled(stopping: 0))
        for (shell, step) in [(silentShell, "shell"), (stalledVersion, "version")] {
            let started = Date()
            let status = await detector(shell, timeLimit: 0.2).detect()
            XCTAssertEqual(status, .notInstalled)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            for _ in 0..<50 where !shell.wasCancelled(step) { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(shell.wasCancelled(step), "the \(step) was left running past the time limit")
        }
        XCTAssertTrue(silentShell.runs.isEmpty)
    }

    /// An interactive shell ignores SIGTERM, so stopping it can take longer than the limit; the answer does not wait,
    /// and an environment it tells after the limit starts no version command.
    func testTimeoutDoesNotWaitForAShellThatIsSlowToStop() async throws {
        let shell = FakeShell(login: .answer(login("/bin"), after: 0.6), version: .answer(ShellOutput(status: 0, stdout: "0.2.0\n")))
        let started = Date()
        let checker = detector(shell, timeLimit: 0.2)
        let probe = checker.start()
        let status = await checker.detect(probe)
        XCTAssertEqual(status, .notInstalled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        await probe.ended()
        XCTAssertTrue(shell.runs.isEmpty)
    }

    func testACancelledCheckEndsAtOnceAsNotInstalled() async {
        let shell = FakeShell(login: .answer(login("/bin")), version: .answer(ShellOutput(status: 0, stdout: "0.2.0\n"), after: 3))
        let started = Date()
        let checker = detector(shell)
        let task = Task { await checker.detect() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let status = await task.value
        XCTAssertEqual(status, .notInstalled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// The shell line, run by a stand-in login shell that prints around it, is given `-ic`; only the environment counts.
    func testTheLoginShellTellsTheEnvironmentItsStartupFilesSet() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shellPath = folder.appendingPathComponent("shell").path
        try """
            #!/bin/sh
            echo "$1" > '\(folder.path)/flags'
            echo 'Welcome back'
            PATH=/login/bin:/usr/bin:/bin; export PATH
            SUBSET_LOGIN='a b=c'; export SUBSET_LOGIN
            unset SUBSET_UNSET_BY_LOGIN
            cd '\(folder.path)'; PWD=/usr; export PWD
            eval "$2"
            echo bye
            exit 3

            """.write(toFile: shellPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellPath)
        setenv("SUBSET_UNSET_BY_LOGIN", "1", 1)
        defer { unsetenv("SUBSET_UNSET_BY_LOGIN") }
        // A folder a crashed check left behind is deleted.
        let stale = FileManager.default.temporaryDirectory.appendingPathComponent("subset-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: stale.path)
        let found = Found()
        await LoginShell(path: shellPath).readEnvironment(timeout: 5) { found.paths.append($0) }
        XCTAssertEqual(found.paths.count, 1)
        XCTAssertEqual(found.paths.first?.variables["PATH"], "/login/bin:/usr/bin:/bin")
        XCTAssertEqual(found.paths.first?.variables["SUBSET_LOGIN"], "a b=c")
        XCTAssertNil(found.paths.first?.variables["SUBSET_UNSET_BY_LOGIN"])
        // The folder the shell is in, not the PWD it exported.
        XCTAssertEqual(found.paths.first?.directory, realpath(folder.path, nil).map { String(cString: $0) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a stale environment snapshot was left")
        XCTAssertEqual(LoginShell.environment(Data("A=1\u{0}B=x=y\u{0}=bad\u{0}C\u{0}".utf8)), ["A": "1", "B": "x=y"])
        XCTAssertEqual(try String(contentsOfFile: folder.path + "/flags", encoding: .utf8), "-ic\n")
        await LoginShell(path: folder.path + "/no-such-shell").readEnvironment(timeout: 1) { found.paths.append($0) }
        XCTAssertEqual(found.paths.count, 1)
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

    func testTheUsersShellIsAnAbsoluteExecutablePathOrZsh() {
        let executable: (String) -> Bool = { $0 != "/missing/fish" }
        XCTAssertEqual(LoginShell.resolve(account: "/bin/bash", environment: "/bin/zsh", isExecutable: executable), "/bin/bash")
        XCTAssertEqual(LoginShell.resolve(account: "/missing/fish", environment: "/bin/ksh", isExecutable: executable), "/bin/ksh")
        XCTAssertEqual(LoginShell.resolve(account: "bash", environment: "zsh", isExecutable: executable), "/bin/zsh")
        XCTAssertEqual(LoginShell.resolve(account: nil, environment: nil, isExecutable: executable), "/bin/zsh")
    }

    @MainActor
    func testTheModelShowsCheckingThenTheResultAndRunsOneCheckAtATime() async throws {
        let shell = FakeShell(login: .answer(login("/bin")), version: .answer(ShellOutput(status: 0, stdout: "0.2.0\n"), after: 0.3))
        let model = CommandLineModel(detector: detector(shell))
        XCTAssertEqual(model.status, .checking)
        let first = Task { await model.check() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(model.isChecking)
        await model.check()
        await first.value
        XCTAssertEqual(model.status, .installed(version: "0.2.0"))
        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(shell.pathTimeouts.count, 1)

        let missing = CommandLineModel(detector: detector(FakeShell(login: .answer(login("/bin")), version: .answer(ShellOutput(status: 127, stdout: "")))))
        await missing.check()
        XCTAssertEqual(missing.status, .notInstalled)
    }

    /// Quitting stops a shell or a version command that the time limit already gave up on (its check shows "not
    /// installed" while it is still being stopped) and waits until it has ended.
    @MainActor
    func testStoppingTheModelWaitsForAShellOrVersionCommandGivenUpAtTheTimeLimit() async throws {
        let shells = [
            (FakeShell(login: .hangUntilCancelled(stopping: 0.5), version: .answer(nil)), "shell"),
            (FakeShell(login: .answer(login("/bin")), version: .hangUntilCancelled(stopping: 0.5)), "version"),
        ]
        for (shell, step) in shells {
            let model = CommandLineModel(detector: detector(shell, timeLimit: 0.1))
            await model.check()
            XCTAssertEqual(model.status, .notInstalled)
            XCTAssertTrue(model.hasRunningShell)
            XCTAssertFalse(shell.hasEnded(step))
            await model.stop()
            XCTAssertTrue(shell.hasEnded(step), "stop returned before the \(step) had ended")
            XCTAssertFalse(model.hasRunningShell)
        }
    }

    /// Quitting during a check stops its shell, waits for it, shows "not installed" and starts no new check.
    @MainActor
    func testStoppingTheModelStopsARunningCheckAndStartsNoOther() async throws {
        let shell = FakeShell(login: .answer(login("/bin")), version: .hangUntilCancelled(stopping: 0.3))
        let model = CommandLineModel(detector: detector(shell, timeLimit: 30))
        let check = Task { await model.check() }
        for _ in 0..<50 where shell.runs.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(model.isChecking)
        let started = Date()
        await model.stop()
        XCTAssertTrue(shell.wasCancelled("version"))
        XCTAssertTrue(shell.hasEnded("version"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        await check.value
        XCTAssertEqual(model.status, .notInstalled)
        await model.check()
        XCTAssertEqual(shell.pathTimeouts.count, 1)
        XCTAssertFalse(model.isChecking)
    }

    /// A shell that never ends does not hold quitting past the limit.
    @MainActor
    func testStoppingTheModelWaitsNoLongerThanItsLimit() async throws {
        let shell = FakeShell(login: .answer(login("/bin"), after: 5), version: .answer(nil))
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
        let older = InstalledCopy(path: "/Applications/Old.app", folder: "/Applications", version: "0.0.1", build: "1", channel: nil)
        let installed = ["timer": [copy], "breaks": [copy], "future": [older, copy], "system": [], "gone": [copy]]
        // The first copy, which `subset` runs, decides: here only X.app has the helpers.
        let examples = HelperExamples.examples(apps: apps, installed: installed) { bundle, _ in bundle != "/Applications/X.app" }
        XCTAssertEqual(examples.map(\.example), [
            "subset timer list", "subset future --help", "subset future-two --help",
        ])
        XCTAssertEqual(examples.map(\.appName), ["Timer", "Future", "Future"])
        XCTAssertEqual(examples.map(\.command), ["timer", "future", "future-two"])
        XCTAssertEqual(examples.map(\.missingFromCopy), [false, true, true])
        XCTAssertEqual(examples.map(\.npmFallback), [true, false, false])
        // Only nothing at the path, through real folders, is missing: a dangling link there or on the way, or a folder
        // there, is not (subset refuses those itself).
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-helpers-\(UUID().uuidString)")
        let helpers = folder.appendingPathComponent("X.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers.appendingPathComponent("future"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: helpers.appendingPathComponent("timer").path, withDestinationPath: "/no/such/file")
        let resources = folder.appendingPathComponent("X.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: resources.appendingPathComponent("minutes-cli").path, withDestinationPath: "/no/such/folder")
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = InstalledCopy(path: folder.appendingPathComponent("X.app").path, folder: "/Applications", version: "0.1.0", build: "1", channel: nil)
        let onDisk = HelperExamples.examples(
            apps: [app("timer", "Timer", helpers: [helper("timer")]), app("minutes", "Minutes", helpers: [helper("minutes", kind: "node")]), apps[4]],
            installed: ["timer": [local], "minutes": [local], "future": [local]]
        )
        XCTAssertEqual(onDisk.map(\.missingFromCopy), [false, false, false, true])
        XCTAssertEqual(examples[0].guide.absoluteString, "https://github.com/21nCo/subset/blob/dev/packages/timer-cli/README.md#agent-skill")
        XCTAssertEqual(
            examples[1].guide.absoluteString,
            "https://github.com/21nCo/subset/blob/dev/packages/subset-dev/README.md#commands-bundled-in-mac-apps"
        )
        XCTAssertEqual(HelperExamples.examples(apps: apps, installed: [:]), [])
        XCTAssertEqual(HelperExamples.setupCommand, "npm i -g subset.dev")
    }

    /// Only a `subset` older than `minimumLauncherVersion` is known to run no bundled command; the `subset.dev` in this
    /// checkout is not older.
    func testOnlyALauncherOlderThanTheMinimumVersionIsKnownToRunNoBundledCommand() throws {
        for version in ["0.1.1", "0.1.99", "0.0.9", "0.1.1-beta.3"] {
            XCTAssertTrue(HelperExamples.predatesBundledCommands(version), version)
        }
        for version in ["0.2.0", "0.2.0-beta.1", "0.2.1-beta.1", "0.10.0", "1.0.0", "0.2.0+build.5"] {
            XCTAssertFalse(HelperExamples.predatesBundledCommands(version), version)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
        let package = try Data(contentsOf: root.appendingPathComponent("packages/subset-dev/package.json"))
        let version = try XCTUnwrap((JSONSerialization.jsonObject(with: package) as? [String: Any])?["version"] as? String)
        XCTAssertFalse(HelperExamples.predatesBundledCommands(version), "subset.dev \(version) is older than minimumLauncherVersion")
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

    /// A login environment with only `PATH`.
    private func login(_ path: String) -> LoginEnvironment {
        LoginEnvironment(variables: ["PATH": path], directory: nil)
    }

    private func detector(_ shell: FakeShell, timeLimit: TimeInterval = SubsetCommandDetector.timeLimit) -> SubsetCommandDetector {
        SubsetCommandDetector(shell: shell, timeLimit: timeLimit)
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

/// The environments a login shell told.
private final class Found: @unchecked Sendable {
    private let lock = NSLock()
    private var told: [LoginEnvironment] = []
    var paths: [LoginEnvironment] {
        get { lock.withLock { told } }
        set { lock.withLock { told = newValue } }
    }
}

/// A login shell and version command that answer as told and record what they were asked to run, and whether each step
/// ("shell", "version") was cancelled and has ended.
private final class FakeShell: CommandShell, @unchecked Sendable {
    enum Behavior<T: Sendable>: Sendable {
        /// Answers after `after` seconds, then runs `thenRun` seconds more, whether or not it is cancelled meanwhile.
        case answer(T, after: TimeInterval = 0, thenRun: TimeInterval = 0)
        /// Runs until cancelled, then takes `stopping` seconds to end, as a group being stopped does.
        case hangUntilCancelled(stopping: TimeInterval)
    }

    private let login: Behavior<LoginEnvironment?>
    private let version: Behavior<ShellOutput?>
    private let lock = NSLock()
    private var timeouts: [TimeInterval] = []
    private var recorded: [(command: [String], environment: [String: String], directory: String?, timeout: TimeInterval)] = []
    private var cancelled: Set<String> = []
    private var ended: Set<String> = []

    init(login: Behavior<LoginEnvironment?>, version: Behavior<ShellOutput?>) {
        self.login = login
        self.version = version
    }

    var pathTimeouts: [TimeInterval] { lock.withLock { timeouts } }
    var runs: [(command: [String], environment: [String: String], directory: String?, timeout: TimeInterval)] { lock.withLock { recorded } }
    func wasCancelled(_ step: String) -> Bool { lock.withLock { cancelled.contains(step) } }
    func hasEnded(_ step: String) -> Bool { lock.withLock { ended.contains(step) } }

    func readEnvironment(timeout: TimeInterval, found: @escaping @Sendable (LoginEnvironment) -> Void) async {
        lock.withLock { timeouts.append(timeout) }
        _ = await act(login, step: "shell") { if let environment = $0 { found(environment) } }
    }

    func run(_ path: String, _ arguments: [String], environment: [String: String], directory: String?, timeout: TimeInterval) async -> ShellOutput? {
        lock.withLock { recorded.append(([path] + arguments, environment, directory, timeout)) }
        return await act(version, step: "version") { _ in } ?? nil
    }

    private func act<T: Sendable>(_ behavior: Behavior<T>, step: String, answered: (T) -> Void) async -> T? {
        defer { lock.withLock { _ = ended.insert(step) } }
        switch behavior {
        case let .answer(value, after, thenRun):
            await Self.pause(after)
            answered(value)
            await Self.pause(thenRun)
            return value
        case .hangUntilCancelled(let stopping):
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if Task.isCancelled { lock.withLock { _ = cancelled.insert(step) } }
            await Self.pause(stopping)
            return nil
        }
    }

    /// Waits even when cancelled.
    private static func pause(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        await Task.detached { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }.value
    }
}

/// The check with real zsh, bash and sh login shells run with no terminal (as `ToolRunner` runs them), a made-up home
/// folder holding their startup files, and a stand-in `subset` on the PATH.
final class CommandLineLoginShellTests: XCTestCase {
    /// A complete answer counts at once even when an EXIT trap keeps the shell running past the limit; the shell is
    /// still tracked, and stopping the model ends it and the trap's work, also when a startup file turned job control on.
    @MainActor
    func testAnAnswerBeforeTheLimitDoesNotWaitForTheShellToEnd() async throws {
        // zsh with no terminal cannot turn job control on (`set -m` fails and ends .zshrc).
        let trap = "trap '\"$SUBSET_TEST_FOLDER/bin/subset\" --trap' EXIT\n"
        let home = [".bash_profile": "set -m\n" + trap, ".zshrc": trap]
        let subset = "if [ \"$1\" = --trap ]; then echo $$ > \"$SUBSET_TEST_FOLDER/trap-pid\"; exec sleep 120; fi\necho 1.2.3\n"
        for shell in ["/bin/bash", "/bin/zsh"] {
            let fixture = try Fixture(home: home, subset: subset)
            var pid: pid_t = 0
            defer {
                if pid > 0 { kill(pid, SIGKILL) }
                fixture.remove()
            }
            let model = CommandLineModel(detector: SubsetCommandDetector(shell: LoginShell(path: shell)))
            let started = Date()
            await model.check()
            XCTAssertEqual(model.status, .installed(version: "1.2.3"), shell)
            XCTAssertLessThan(Date().timeIntervalSince(started), 4, shell)
            XCTAssertTrue(model.hasRunningShell, "\(shell): the shell running its EXIT trap is no longer tracked")
            let pidFile = fixture.folder.appendingPathComponent("trap-pid")
            for _ in 0..<100 where pid == 0 {
                pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                if pid == 0 { try await Task.sleep(nanoseconds: 30_000_000) }
            }
            XCTAssertGreaterThan(pid, 0, "\(shell): the EXIT trap never ran")
            await model.stop()
            XCTAssertFalse(model.hasRunningShell, shell)
            let ended = await Self.ends(pid)
            XCTAssertTrue(ended, "\(shell): the EXIT trap's work is still running after the model stopped")
        }
    }

    /// The version command gets what the login files set: an unset variable stays unset, an exported one is there, and a
    /// relative PATH entry is found from the folder they changed to, even when they exported another PWD.
    func testTheVersionCommandRunsInTheLoginShellsEnvironmentAndDirectory() async throws {
        let profile = "unset NODE_OPTIONS\nSUBSET_LOGIN=yes; export SUBSET_LOGIN\ncd \"$SUBSET_TEST_FOLDER\"\nPWD=/usr; export PWD\nPATH=\"bin:$PATH\"; export PATH\n"
        let fixture = try Fixture(
            home: [".bash_profile": profile],
            subset: "[ -z \"$NODE_OPTIONS\" ] && [ \"$SUBSET_LOGIN\" = yes ] && [ -d bin ] && echo 1.2.3\n", onPath: false
        )
        setenv("NODE_OPTIONS", "--require /no/such/preload.js", 1)
        defer { fixture.remove() }
        let found = await SubsetCommandDetector(shell: LoginShell(path: "/bin/bash")).detect()
        XCTAssertEqual(found, .installed(version: "1.2.3"))
    }

    /// A stalled `subset` is stopped when the check times out and when the model stops, also when a startup file's
    /// DEBUG trap turns job control on, which would give a command the shell runs a process group of its own.
    @MainActor
    func testATimedOutOrQuitCheckStopsTheStalledSubsetCommandUnderEachLoginShell() async throws {
        let home = [".bash_profile": "trap 'set -m' DEBUG\n", ".profile": "trap 'set -m' DEBUG\n"]
        for shell in shells {
            let fixture = try Fixture(home: home, subset: "echo $$ > \"$SUBSET_TEST_FOLDER/pid\"\nexec sleep 120\n")
            var pid: pid_t = 0
            defer {
                if pid > 0 { kill(pid, SIGKILL) }
                fixture.remove()
            }
            let model = CommandLineModel(detector: SubsetCommandDetector(shell: LoginShell(path: shell), timeLimit: 1.5))
            await model.check()
            let recorded = (try? String(contentsOf: fixture.folder.appendingPathComponent("pid"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pid = try XCTUnwrap(recorded.flatMap { pid_t($0) }, "\(shell): the stand-in subset never ran")
            XCTAssertEqual(model.status, .notInstalled, shell)
            await model.stop()
            XCTAssertFalse(model.hasRunningShell, shell)
            let ended = await Self.ends(pid)
            XCTAssertTrue(ended, "\(shell): the stalled subset command is still running after the check was stopped")
        }
    }

    /// Each login shell, csh and tcsh too, finds `subset` on the PATH only its login file sets, and nothing without it.
    func testEachLoginShellFindsSubsetOnThePathItsLoginFileSets() async throws {
        let posix = "PATH=\"$SUBSET_TEST_FOLDER/bin:$PATH\"; export PATH\n"
        let home = [".profile": posix, ".zprofile": posix, ".login": "setenv PATH \"${SUBSET_TEST_FOLDER}/bin:${PATH}\"\n"]
        for shell in shells {
            for (files, status) in [(home, SubsetCommandStatus.installed(version: "1.2.3")), ([:], .notInstalled)] {
                let fixture = try Fixture(home: files, subset: "echo 1.2.3\n", onPath: false)
                defer { fixture.remove() }
                let found = await SubsetCommandDetector(shell: LoginShell(path: shell)).detect()
                XCTAssertEqual(found, status, "\(shell) with \(files.isEmpty ? "no" : "its") login file")
            }
        }
    }

    /// What the shell prints, here a DEBUG trap printing a version before each command, never counts as the answer.
    func testOnlyTheVersionCommandsOwnOutputCounts() async throws {
        let home = [".bash_profile": "trap 'case \"$BASH_COMMAND\" in *--version*) echo 9.9.9;; esac' DEBUG\n"]
        for (subset, status) in [("exit 0\n", SubsetCommandStatus.notInstalled), ("echo 1.2.3\n", .installed(version: "1.2.3"))] {
            let fixture = try Fixture(home: home, subset: subset)
            defer { fixture.remove() }
            let found = await SubsetCommandDetector(shell: LoginShell(path: "/bin/bash")).detect()
            XCTAssertEqual(found, status, subset)
        }
    }

    /// Whether process `pid` is gone within 2 seconds.
    private static func ends(_ pid: pid_t) async -> Bool {
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return false
    }

    private let shells = ["/bin/zsh", "/bin/bash", "/bin/sh", "/bin/ksh", "/bin/dash", "/bin/tcsh", "/bin/csh"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }

    /// A folder with `home` (HOME for the test) and `bin/subset`, first on the PATH unless `onPath` is false; the
    /// environment is restored by `remove()`.
    private struct Fixture {
        let folder: URL
        let saved: [String: String?]

        init(home files: [String: String], subset: String, onPath: Bool = true) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-command-\(UUID().uuidString)")
            let home = folder.appendingPathComponent("home")
            let bin = folder.appendingPathComponent("bin")
            for directory in [home, bin] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            for (name, text) in files { try text.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            let fake = bin.appendingPathComponent("subset")
            try ("#!/bin/sh\n" + subset).write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            let environment = ProcessInfo.processInfo.environment
            saved = ["PATH", "HOME", "ZDOTDIR", "SUBSET_TEST_FOLDER", "NODE_OPTIONS"].reduce(into: [:]) { $0[$1] = environment[$1] }
            if onPath { setenv("PATH", "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")", 1) }
            setenv("HOME", home.path, 1)
            setenv("SUBSET_TEST_FOLDER", folder.path, 1)
            unsetenv("ZDOTDIR")
        }

        func remove() {
            for (name, value) in saved {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
