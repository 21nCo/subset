import Darwin
import Foundation

/// Whether the `subset` command is on the user's PATH.
public enum SubsetCommandStatus: Equatable, Sendable {
    /// The check has not finished.
    case checking
    /// `subset --version` printed this version.
    case installed(version: String)
    /// `subset` was not found, failed, printed no version, or did not answer within the time limit.
    case notInstalled
}

/// What a shell command did: its exit status (nil when it was stopped or ended by a signal) and its standard output.
public struct ShellOutput: Equatable, Sendable {
    public var status: Int32?
    public var stdout: String

    public init(status: Int32?, stdout: String) {
        self.status = status
        self.stdout = stdout
    }
}

/// Runs one command line in a shell. Nil when it could not be started or was cancelled.
public protocol CommandShell: Sendable {
    func run(_ command: String, timeout: TimeInterval) async -> ShellOutput?
}

/// The user's login shell, run as an interactive login shell (`-ilc`, as Minutes finds Node.js), so the PATH set in
/// its startup files (nvm, fnm, Homebrew) applies. It runs with nothing on its standard input, in its own process group,
/// and is stopped with everything it started after `timeout` (`ToolRunner`).
public struct LoginShell: CommandShell {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// The account's login shell, else `$SHELL`, else /bin/zsh; each only when it is an absolute path to an executable.
    public static func user() -> LoginShell {
        let account = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }
        let environment = ProcessInfo.processInfo.environment["SHELL"]
        return LoginShell(path: resolve(account: account, environment: environment) { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func resolve(account: String?, environment: String?, isExecutable: (String) -> Bool) -> String {
        [account, environment].compactMap { $0 }.first { $0.hasPrefix("/") && isExecutable($0) } ?? "/bin/zsh"
    }

    public func run(_ command: String, timeout: TimeInterval) async -> ShellOutput? {
        guard let result = try? await ToolRunner.run(path, ["-ilc", command], timeout: timeout) else { return nil }
        return ShellOutput(status: result.status, stdout: String(decoding: result.stdout, as: UTF8.self))
    }
}

/// One check's shell run. It may outlive the answer: a shell that has not answered by the time limit is stopped, and
/// stopping an interactive shell with everything it started can take longer (`ToolRunner`: SIGTERM, then SIGKILL).
public struct SubsetCommandProbe: Sendable {
    let token: String
    let run: Task<ShellOutput?, Never>

    /// Stops the shell if it still runs.
    public func cancel() {
        run.cancel()
    }

    /// Returns once the shell has ended or been stopped with everything it started.
    public func ended() async {
        _ = await run.value
    }
}

/// Finds `subset` by running `/usr/bin/env subset --version` in the user's login shell, for 5 seconds at most. Any
/// failure is `notInstalled`; nothing is installed and no error is raised.
public struct SubsetCommandDetector: Sendable {
    public static let command = "/usr/bin/env subset --version"
    public static let timeLimit: TimeInterval = 5
    /// What `subset --version` prints: a version such as 0.2.0 or 0.2.1-beta.1, at most 64 characters.
    static let versionPattern = #"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#

    let shell: any CommandShell
    let timeLimit: TimeInterval
    let token: @Sendable () -> String

    /// `token` names each check's output markers; a new random one by default.
    public init(
        shell: any CommandShell, timeLimit: TimeInterval = SubsetCommandDetector.timeLimit,
        token: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.shell = shell
        self.timeLimit = timeLimit
        self.token = token
    }

    public static func standard() -> SubsetCommandDetector {
        SubsetCommandDetector(shell: LoginShell.user())
    }

    /// The shell line: the command between a start marker and an end marker printed only when the command exits 0, so
    /// what startup and logout files or an EXIT trap print, and the shell's own exit status, do not count. `echo`, `;`
    /// and `&&` mean the same in sh, bash, zsh and fish.
    static func script(token: String) -> String {
        "echo \(startMarker(token)); \(command) && echo \(endMarker(token))"
    }

    static func startMarker(_ token: String) -> String { "subset-check-\(token)-start" }
    static func endMarker(_ token: String) -> String { "subset-check-\(token)-end" }

    /// Checks once: `start()`, then `detect(_:)`.
    public func detect() async -> SubsetCommandStatus {
        await detect(start())
    }

    /// Starts the shell. Its run belongs to the caller, who can stop it and wait for it to end (`SubsetCommandProbe`).
    public func start() -> SubsetCommandProbe {
        let shell = shell
        let token = token()
        let limit = timeLimit
        return SubsetCommandProbe(token: token, run: Task.detached { await shell.run(Self.script(token: token), timeout: limit) })
    }

    /// `installed` with the version when the command exited 0 and printed a version between the markers; otherwise
    /// `notInstalled`, also when the shell has not answered within the time limit or the caller is cancelled. Then the
    /// probe is stopped but not waited for (an interactive shell ignores SIGTERM until it is killed).
    public func detect(_ probe: SubsetCommandProbe) async -> SubsetCommandStatus {
        guard let answer = await Self.within(timeLimit, { await probe.run.value }) else {
            probe.cancel()
            return .notInstalled
        }
        guard let output = answer, let version = Self.version(in: output.stdout, token: probe.token) else { return .notInstalled }
        return .installed(version: version)
    }

    /// The text between the start marker and the end marker after it, when it is one version.
    static func version(in stdout: String, token: String) -> String? {
        guard let start = stdout.range(of: startMarker(token)),
              let end = stdout.range(of: endMarker(token), range: start.upperBound..<stdout.endIndex) else { return nil }
        let line = stdout[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count <= 64, line.range(of: versionPattern, options: .regularExpression) != nil else { return nil }
        return line
    }

    /// The operation's result, or nil once `seconds` have passed or the caller is cancelled; the operation is then
    /// cancelled and left to finish on its own.
    static func within<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let race = Race<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let work = Task { race.finish(await operation()) }
                race.start(continuation, work: work)
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    race.finish(nil)
                }
            }
        } onCancel: {
            race.finish(nil)
        }
    }
}

/// The first of an operation's result, its deadline and a cancel resumes the caller; the others are ignored.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var work: Task<Void, Never>?
    private var result: T??

    func start(_ continuation: CheckedContinuation<T?, Never>, work: Task<Void, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            if result == nil { work.cancel() }
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        self.work = work
        lock.unlock()
    }

    func finish(_ value: T?) {
        lock.lock()
        guard result == nil else { return lock.unlock() }
        result = .some(value)
        let continuation = continuation
        let work = work
        self.continuation = nil
        self.work = nil
        lock.unlock()
        if value == nil { work?.cancel() }
        continuation?.resume(returning: value)
    }
}
