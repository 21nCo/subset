import Foundation
@testable import SubsetCore
import XCTest

/// The Command Line section: finding `subset` through a shell (a fake one, except where the login shell itself is run),
/// and the examples for the commands installed apps bundle, from the feed's `helpers`.
final class CommandLineTests: XCTestCase {
    // MARK: Detection

    func testFoundRunsTheVersionCommandForFiveSecondsAndShowsTheVersion() async {
        let shell = FakeShell(.output(ShellOutput(status: 0, stdout: "0.2.0\n")))
        let status = await SubsetCommandDetector(shell: shell).detect()
        XCTAssertEqual(status, .installed(version: "0.2.0"))
        XCTAssertEqual(shell.calls.map(\.command), ["/usr/bin/env subset --version"])
        XCTAssertEqual(shell.calls.map(\.timeout), [5])
    }

    func testFoundAfterLinesAStartupFilePrints() async {
        let shell = FakeShell(.output(ShellOutput(status: 0, stdout: "Welcome back\n  0.2.1-beta.1  \n\n")))
        let status = await SubsetCommandDetector(shell: shell).detect()
        XCTAssertEqual(status, .installed(version: "0.2.1-beta.1"))
    }

    func testMissingOrUnusableIsNotInstalled() async {
        let outputs: [ShellOutput?] = [
            ShellOutput(status: 127, stdout: ""),  // env: subset: No such file or directory
            ShellOutput(status: 1, stdout: "0.2.0\n"),
            ShellOutput(status: nil, stdout: "0.2.0\n"),  // stopped or ended by a signal
            ShellOutput(status: 0, stdout: ""),
            ShellOutput(status: 0, stdout: "zsh: command not found: subset\n"),
            ShellOutput(status: 0, stdout: "0.2.0\u{1b}[31m\n"),
            ShellOutput(status: 0, stdout: "0.2.0-" + String(repeating: "a", count: 60) + "\n"),
            nil,  // the shell could not be started
        ]
        for output in outputs {
            let status = await SubsetCommandDetector(shell: FakeShell(output.map(FakeShell.Behavior.output) ?? .unavailable)).detect()
            XCTAssertEqual(status, .notInstalled, "\(String(describing: output))")
        }
    }

    func testTimeoutIsNotInstalledAndStopsTheShell() async throws {
        let shell = FakeShell(.hangUntilCancelled)
        let started = Date()
        let status = await SubsetCommandDetector(shell: shell, timeLimit: 0.2).detect()
        XCTAssertEqual(status, .notInstalled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        for _ in 0..<50 where !shell.wasCancelled { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(shell.wasCancelled, "the shell was left running past the time limit")
    }

    /// An interactive shell ignores SIGTERM, so stopping it can take longer than the limit; the answer does not wait.
    func testTimeoutDoesNotWaitForAShellThatIsSlowToStop() async {
        let shell = FakeShell(.ignoreCancelThenAnswer(seconds: 3, ShellOutput(status: 0, stdout: "0.2.0\n")))
        let started = Date()
        let status = await SubsetCommandDetector(shell: shell, timeLimit: 0.2).detect()
        XCTAssertEqual(status, .notInstalled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testACancelledCheckEndsAtOnceAsNotInstalled() async {
        let shell = FakeShell(.ignoreCancelThenAnswer(seconds: 3, ShellOutput(status: 0, stdout: "0.2.0\n")))
        let started = Date()
        let task = Task { await SubsetCommandDetector(shell: shell).detect() }
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

    func testTheUsersShellIsAnAbsoluteExecutablePathOrZsh() {
        let executable: (String) -> Bool = { $0 != "/missing/fish" }
        XCTAssertEqual(LoginShell.resolve(account: "/bin/bash", environment: "/bin/zsh", isExecutable: executable), "/bin/bash")
        XCTAssertEqual(LoginShell.resolve(account: "/missing/fish", environment: "/bin/ksh", isExecutable: executable), "/bin/ksh")
        XCTAssertEqual(LoginShell.resolve(account: "bash", environment: "zsh", isExecutable: executable), "/bin/zsh")
        XCTAssertEqual(LoginShell.resolve(account: nil, environment: nil, isExecutable: executable), "/bin/zsh")
    }

    @MainActor
    func testTheModelShowsCheckingThenTheResultAndRunsOneCheckAtATime() async throws {
        let shell = FakeShell(.ignoreCancelThenAnswer(seconds: 0.3, ShellOutput(status: 0, stdout: "0.2.0\n")))
        let model = CommandLineModel(detector: SubsetCommandDetector(shell: shell))
        XCTAssertEqual(model.status, .checking)
        let first = Task { await model.check() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(model.isChecking)
        await model.check()
        await first.value
        XCTAssertEqual(model.status, .installed(version: "0.2.0"))
        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(shell.calls.count, 1)

        let missing = CommandLineModel(detector: SubsetCommandDetector(shell: FakeShell(.output(ShellOutput(status: 127, stdout: "")))))
        await missing.check()
        XCTAssertEqual(missing.status, .notInstalled)
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

/// A shell that answers as told and records what it was asked to run.
private final class FakeShell: CommandShell, @unchecked Sendable {
    enum Behavior {
        case output(ShellOutput)
        case unavailable
        case hangUntilCancelled
        /// Answers after `seconds` whether or not it is cancelled meanwhile.
        case ignoreCancelThenAnswer(seconds: TimeInterval, ShellOutput)
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var recorded: [(command: String, timeout: TimeInterval)] = []
    private var cancelled = false

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var calls: [(command: String, timeout: TimeInterval)] { lock.withLock { recorded } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func run(_ command: String, timeout: TimeInterval) async -> ShellOutput? {
        lock.withLock { recorded.append((command, timeout)) }
        switch behavior {
        case .output(let output):
            return output
        case .unavailable:
            return nil
        case .hangUntilCancelled:
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if Task.isCancelled { lock.withLock { cancelled = true } }
            return nil
        case let .ignoreCancelThenAnswer(seconds, output):
            await Task.detached { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }.value
            return output
        }
    }
}
