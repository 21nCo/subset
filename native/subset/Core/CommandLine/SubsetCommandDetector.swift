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

/// What the version command did: its exit status (nil when it was stopped or ended by a signal) and its standard output.
public struct ShellOutput: Equatable, Sendable {
    public var status: Int32?
    public var stdout: String

    public init(status: Int32?, stdout: String) {
        self.status = status
        self.stdout = stdout
    }
}

/// The user's login shell, which only tells the environment its startup files set, and a runner for the version command.
public protocol CommandShell: Sendable {
    /// Runs the login shell until it ends or is stopped (`timeout`, or the calling task cancelled). `found` gets its
    /// exported environment and working directory, at most once, as soon as they are known, which can be well before
    /// the shell ends (an EXIT trap or a logout file still runs).
    func readEnvironment(timeout: TimeInterval, found: @escaping @Sendable (LoginEnvironment) -> Void) async
    /// Runs a program as the app's own process with `environment`, in `directory` when given. Nil when it could not be
    /// started or was cancelled.
    func run(_ path: String, _ arguments: [String], environment: [String: String], directory: String?, timeout: TimeInterval) async -> ShellOutput?
}

/// What the login shell's startup files left: its exported variables and the folder it is in.
public struct LoginEnvironment: Equatable, Sendable {
    public var variables: [String: String]
    public var directory: String?

    public init(variables: [String: String], directory: String?) {
        self.variables = variables
        self.directory = directory
    }
}

/// The user's login shell, run as an interactive login shell, so the environment set in its startup files (a PATH from
/// nvm, fnm or Homebrew, an unset NODE_OPTIONS) applies. It is started as login(1) starts one, with `-` before its name as argument zero, and `-ic`, which zsh, bash,
/// sh, ksh, dash, fish, tcsh and csh all accept (tcsh and csh reject `-ilc`). It runs with nothing on its standard
/// input, in a session of its own, and is stopped with everything it started after `timeout` (`ToolRunner`).
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

    /// The shell line runs one process, awk, which writes its environment (the shell's exported variables) and the
    /// folder the shell is in (every line of `pwd -P`: PWD can be unset or name another folder) to `channel`, a named
    /// pipe only the app reads, framed by a line made up for this check: `<mark>\n`, each NAME=value and the folder
    /// followed by NUL, `<mark>\n`. What passes through a named pipe is never written to disk, and no redirection of the
    /// shell's input, output or errors by a startup file changes where it goes. No shell command runs inside the frame.
    /// The line reads the same in every shell above (single quotes, no `!`; `channel` is letters, digits, `.`, `-` and
    /// `/` only). It starts with `set +m` (job control off), so a startup file that turns it on does not give the work of
    /// an EXIT trap or logout file a process group of its own; csh and tcsh only print an error. The shell leads a
    /// session of its own, so a job that still gets a group of its own is stopped with it.
    static func script(mark: String, channel: String) -> String {
        let write = "> \"\(channel)\""
        return "set +m; /usr/bin/awk 'BEGIN { while ((\"/bin/pwd -P\" | getline line) > 0) folder = folder (n++ ? \"\\n\" : \"\") line; "
            + "printf \"%s\\n\", \"\(mark)\" \(write); for (name in ENVIRON) printf \"%s=%s%c\", name, ENVIRON[name], 0 \(write); "
            + "printf \"%s%c%s\\n\", folder, 0, \"\(mark)\" \(write) }'"
    }

    /// The environment and folder in a complete frame of `script(mark:)` in `output`, or nil until the frame is complete.
    /// An empty environment or folder is no answer.
    static func snapshot(in output: Data, mark: String) -> LoginEnvironment? {
        let line = Data((mark + "\n").utf8)
        guard let start = output.range(of: line), let end = output.range(of: Data([0]) + line, in: start.upperBound..<output.endIndex) else {
            return nil
        }
        var entries = output[start.upperBound..<end.lowerBound].split(separator: 0, omittingEmptySubsequences: false)
        guard let folder = entries.popLast().map({ String(decoding: $0, as: UTF8.self) }), !folder.isEmpty else { return nil }
        let variables = environment(Data(entries.joined(separator: [0])))
        return variables.isEmpty ? nil : LoginEnvironment(variables: variables, directory: folder)
    }

    /// NUL-separated NAME=value entries.
    static func environment(_ data: Data) -> [String: String] {
        let entries = data.split(separator: 0).compactMap { entry -> (String, String)? in
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { return nil }
            return (String(text[..<equals]), String(text[text.index(after: equals)...]))
        }
        return Dictionary(entries, uniquingKeysWith: { _, last in last })
    }

    /// The named pipe is in a folder of its own, only the user's, in /private/tmp (whose path has no character a shell
    /// line would need quoted), which is removed once the shell and everything it started have ended, so no process can
    /// still write to that path. A folder a crash left holds an empty named pipe and nothing else; it is never swept.
    public func readEnvironment(timeout: TimeInterval, found: @escaping @Sendable (LoginEnvironment) -> Void) async {
        var template = Array("/private/tmp/subset-check.XXXXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { return }
        let folder = String(cString: made)
        let channel = folder + "/channel"
        defer {
            unlink(channel)
            rmdir(folder)
        }
        guard mkfifo(channel, 0o600) == 0 else { return }
        // The app holds the writing end too, so the pipe never reads as ended before awk opens it.
        let reader = open(channel, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        let holder = open(channel, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        guard reader >= 0, holder >= 0 else {
            for fd in [reader, holder] where fd >= 0 { close(fd) }
            return
        }
        let mark = "subset-check-" + UUID().uuidString
        let output = Snapshot()
        let queue = DispatchQueue(label: "dev.subset.login-environment")
        // Reads what is there; once more after the shell has ended, before the reader is closed.
        let drain = {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(reader, &buffer, buffer.count)
                guard count > 0 else { return }
                if let snapshot = output.add(Data(buffer[0..<count]), mark: mark) { found(snapshot) }
            }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: reader, queue: queue)
        source.setEventHandler(handler: drain)
        source.setCancelHandler {
            close(reader)
            close(holder)
        }
        source.resume()
        let name = "-" + (path as NSString).lastPathComponent
        _ = try? await ToolRunner.run(path, ["-ic", Self.script(mark: mark, channel: channel)], argv0: name, timeout: timeout, ownSession: true)
        queue.sync(execute: drain)
        source.cancel()
    }

    public func run(_ path: String, _ arguments: [String], environment: [String: String], directory: String?, timeout: TimeInterval) async -> ShellOutput? {
        guard let result = try? await ToolRunner.run(path, arguments, environment: environment, directory: directory, timeout: timeout) else { return nil }
        return ShellOutput(status: result.status, stdout: String(decoding: result.stdout, as: UTF8.self))
    }
}

/// One check: the login shell telling its environment, then the version command run with it, in its directory. Both are the app's own processes
/// and may outlive the answer: a shell can still run its EXIT trap or logout files after the answer is shown, and a run
/// stopped at the time limit takes a moment to end (`ToolRunner`: SIGTERM, then SIGKILL).
public final class SubsetCommandProbe: Sendable {
    let shell: Task<Void, Never>
    let answer: Task<ShellOutput?, Never>
    private let environment: OneShot<LoginEnvironment>

    init(shell: any CommandShell, timeLimit: TimeInterval) {
        let environment = OneShot<LoginEnvironment>()
        let deadline = Date().addingTimeInterval(timeLimit)
        self.environment = environment
        self.shell = Task.detached {
            await shell.readEnvironment(timeout: timeLimit) { environment.set($0) }
            environment.set(nil)
        }
        answer = Task.detached {
            guard let found = await environment.value else { return nil }
            return await shell.run(
                "/usr/bin/env", SubsetCommandDetector.arguments, environment: found.variables, directory: found.directory,
                timeout: max(0, deadline.timeIntervalSinceNow)
            )
        }
    }

    /// Stops the shell and the version command if they still run, and starts no version command.
    public func cancel() {
        environment.set(nil)
        shell.cancel()
        answer.cancel()
    }

    /// Returns once the shell and the version command have ended or been stopped with everything they started.
    public func ended() async {
        await shell.value
        _ = await answer.value
    }
}

/// Finds `subset` by running `/usr/bin/env subset --version` with the environment and working directory of the user's
/// login shell, for 5 seconds at most. Any failure is `notInstalled`; nothing is installed and no error is raised.
public struct SubsetCommandDetector: Sendable {
    public static let command = "/usr/bin/env subset --version"
    static let arguments = ["subset", "--version"]
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

    /// Checks once: `start()`, then `detect(_:)`.
    public func detect() async -> SubsetCommandStatus {
        await detect(start())
    }

    /// Starts the check. Its processes belong to the caller, who can stop them and wait for them to end.
    public func start() -> SubsetCommandProbe {
        SubsetCommandProbe(shell: shell, timeLimit: timeLimit)
    }

    /// `installed` with the version when the version command exited 0 and printed only a version; otherwise
    /// `notInstalled`, also when there is no answer within the time limit or the caller is cancelled. Then the probe
    /// is stopped but not waited for (an interactive shell ignores SIGTERM until it is killed). An answer does not wait
    /// for the shell to end.
    public func detect(_ probe: SubsetCommandProbe) async -> SubsetCommandStatus {
        guard let answer = await Self.within(timeLimit, { await probe.answer.value }) else {
            probe.cancel()
            return .notInstalled
        }
        guard let output = answer, output.status == 0, let version = Self.version(in: output.stdout) else { return .notInstalled }
        return .installed(version: version)
    }

    /// The version command's output, when it is one version.
    static func version(in stdout: String) -> String? {
        let line = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// The shell's standard output so far, until it holds a complete frame, which is told once.
private final class Snapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var told = false

    /// Nil, and nothing more is kept, once a frame was told or past 1 MiB.
    func add(_ chunk: Data, mark: String) -> LoginEnvironment? {
        lock.withLock {
            guard !told, output.count + chunk.count <= ToolRunner.maxOutputBytes else { return nil }
            output.append(chunk)
            guard let snapshot = LoginShell.snapshot(in: output, mark: mark) else { return nil }
            told = true
            output = Data()
            return snapshot
        }
    }
}

/// A value set once (the first `set` wins), awaited by one caller.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: T??
    private var waiter: CheckedContinuation<T?, Never>?

    func set(_ value: T?) {
        lock.lock()
        guard result == nil else { return lock.unlock() }
        result = .some(value)
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: value)
    }

    var value: T? {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }
}
