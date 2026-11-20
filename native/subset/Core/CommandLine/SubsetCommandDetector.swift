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

/// Finds `subset` by running `/usr/bin/env subset --version` in the user's login shell, for 5 seconds at most. Any
/// failure is `notInstalled`; nothing is installed and no error is raised.
public struct SubsetCommandDetector: Sendable {
    public static let command = "/usr/bin/env subset --version"
    public static let timeLimit: TimeInterval = 5
    /// What `subset --version` prints: a version such as 0.2.0 or 0.2.1-beta.1, at most 64 characters.
    static let versionPattern = #"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#

    let shell: any CommandShell
    let timeLimit: TimeInterval

    public init(shell: any CommandShell, timeLimit: TimeInterval = SubsetCommandDetector.timeLimit) {
        self.shell = shell
        self.timeLimit = timeLimit
    }

    public static func standard() -> SubsetCommandDetector {
        SubsetCommandDetector(shell: LoginShell.user())
    }

    /// `installed` with the version when the command exits 0 and its last non-empty output line is a version (a startup
    /// file may print lines before it); otherwise `notInstalled`, also when the shell has not answered within the time
    /// limit, even if stopping it takes longer (an interactive shell ignores SIGTERM until it is killed).
    public func detect() async -> SubsetCommandStatus {
        let shell = shell
        let limit = timeLimit
        let output = await Self.within(limit) { await shell.run(Self.command, timeout: limit) }
        guard let output = output ?? nil, output.status == 0 else { return .notInstalled }
        return Self.version(in: output.stdout).map { .installed(version: $0) } ?? .notInstalled
    }

    static func version(in stdout: String) -> String? {
        let line = stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        guard let line, line.count <= 64, line.range(of: versionPattern, options: .regularExpression) != nil else { return nil }
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
