import Darwin
import Foundation

/// Runs a command in a process group of its own and answers only once the command has exited and no process is left
/// in its group: for a command that changes the disk, whose result, and whatever runs after it, must not overlap with
/// the command or a program it started. At the timeout, once the output passes `outputLimit`, or when the calling task
/// is cancelled, it sends the group `SIGTERM`, then `SIGKILL` after `grace`, and keeps waiting until they have exited.
/// A process that leaves the group (`setsid`, `setpgid`) is not followed. A task already cancelled starts nothing.
public struct ProcessGroupRunner: CommandRunning {
    public static let defaultGrace: Duration = .seconds(3)
    /// The most read from one stream in one turn.
    static let chunkSize = 64 << 10
    /// How many chunks of each stream are read once the group is gone.
    static let finalChunks = 16
    public let outputLimit: Int
    /// How long the group has after `SIGTERM` before `SIGKILL`.
    public let grace: Duration
    public let registry: CommandRegistry
    /// Told after each turn of reading, and after the last read, how many bytes that turn read and how many are kept.
    var onTurn: (@Sendable (_ read: Int, _ kept: Int) -> Void)?

    public init(outputLimit: Int = ProcessCommandRunner.defaultOutputLimit, grace: Duration = ProcessGroupRunner.defaultGrace,
                registry: CommandRegistry = .shared) {
        self.outputLimit = outputLimit
        self.grace = grace
        self.registry = registry
    }

    public func run(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration) async
        -> Result<CommandOutput, CommandFailure> {
        let run = GroupRun(limit: outputLimit, grace: grace, registry: registry, onTurn: onTurn)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                run.start(executable, arguments: arguments, environment: environment, timeout: timeout,
                          continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }
}

/// One command's run. A thread of its own reads the output, reaps the command, watches its group, and stops it; it
/// alone answers once the group is gone.
private final class GroupRun: RegisteredRun, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let grace: Duration
    private let registry: CommandRegistry
    private let onTurn: (@Sendable (Int, Int) -> Void)?
    /// Why the command is being stopped, set by the first of a cancellation and a shutdown.
    private var stopRequest: CommandFailure?
    /// The command's pid, which is also its group's ID; 0 until it has launched.
    private var pid: pid_t = 0
    /// No process is left in the group, so its ID may belong to another one now and is never signalled again.
    private var groupGone = false
    /// A shutdown sent the group `SIGKILL`, so however it ended, the run was stopped.
    private var killedNow = false

    init(limit: Int, grace: Duration, registry: CommandRegistry, onTurn: (@Sendable (Int, Int) -> Void)?) {
        self.limit = limit
        self.grace = grace
        self.registry = registry
        self.onTurn = onTurn
    }

    func cancel() {
        lock.withLock { if stopRequest == nil { stopRequest = .cancelled } }
    }

    /// Sends the group `SIGKILL` now if it has launched, or makes sure it never launches.
    func killNow() {
        lock.withLock {
            if stopRequest == nil { stopRequest = .cancelled }
            if pid > 0, !groupGone {
                killpg(pid, SIGKILL)
                killedNow = true
            }
        }
    }

    func start(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration,
               continuation: CheckedContinuation<Result<CommandOutput, CommandFailure>, Never>) {
        guard registry.register(self) else { return continuation.resume(returning: .failure(.cancelled)) }
        // Launched under the lock, so a cancellation or shutdown either comes first and nothing launches, or finds the
        // pid to signal.
        let launch: Result<(stdout: Int32, stderr: Int32), CommandFailure> = lock.withLock {
            guard stopRequest == nil else { return .failure(.cancelled) }
            return Self.spawn(executable, arguments: arguments, environment: environment).map { launched in
                pid = launched.pid
                return (launched.stdout, launched.stderr)
            }
        }
        switch launch {
        case let .failure(failure):
            registry.remove(self)
            continuation.resume(returning: .failure(failure))
        case let .success(pipes):
            let thread = Thread { [self] in
                let result = monitor(stdout: pipes.stdout, stderr: pipes.stderr, deadline: .now + timeout)
                registry.remove(self)
                continuation.resume(returning: result)
            }
            thread.name = "ProcessGroupRunner"
            thread.start()
        }
    }

    /// Reads the output, reaps the command, and stops the group when asked, at the deadline, or when the output is too
    /// large; returns once the command has exited and its group is gone.
    private func monitor(stdout outFD: Int32, stderr errFD: Int32, deadline: ContinuousClock.Instant)
        -> Result<CommandOutput, CommandFailure> {
        let pid = lock.withLock { self.pid }
        var output = [Data(), Data()]
        var open = [outFD, errFD]
        var status: Int32?
        var reason: CommandFailure?
        var terminatedAt: ContinuousClock.Instant?
        var killed = false
        defer { open.forEach { close($0) } }
        while true {
            var polled = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            if polled.isEmpty { usleep(50_000) } else { _ = poll(&polled, nfds_t(polled.count), 50) }
            // One chunk from each stream a turn, so however fast the group writes, a stop, the deadline, and the
            // escalation to `SIGKILL` below are checked every turn.
            var turn = 0
            for fd in open {
                let chunk = read(fd, into: &output, outFD: outFD, keeping: reason == nil)
                turn += chunk.count
                if !chunk.open {
                    close(fd)
                    open.removeAll { $0 == fd }
                }
            }
            onTurn?(turn, output[0].count + output[1].count)
            if reason == nil, output[0].count + output[1].count > limit { reason = .outputTooLarge }
            if status == nil {
                var raw: Int32 = 0
                let reaped = waitpid(pid, &raw, WNOHANG)
                if reaped == pid { status = raw } else if reaped == -1, errno != EINTR { status = -1 }
            }
            if status != nil, !groupAlive(pid) {
                // What is left in the pipes, up to a bound: whatever a process outside the group still holds open, and
                // may keep writing to, is not waited for.
                var last = 0
                for fd in open {
                    for _ in 0 ..< ProcessGroupRunner.finalChunks {
                        let chunk = read(fd, into: &output, outFD: outFD, keeping: reason == nil)
                        last += chunk.count
                        if !chunk.open || chunk.count == 0 { break }
                    }
                }
                onTurn?(last, output[0].count + output[1].count)
                if reason == nil, output[0].count + output[1].count > limit { reason = .outputTooLarge }
                if reason == nil, lock.withLock({ killedNow }) { reason = .cancelled }
                break
            }
            if reason == nil { reason = lock.withLock { stopRequest } ?? (ContinuousClock.now >= deadline ? .timedOut : nil) }
            if reason != nil, terminatedAt == nil {
                signal(pid, SIGTERM)
                terminatedAt = .now
            } else if let terminatedAt, !killed, ContinuousClock.now >= terminatedAt + grace {
                signal(pid, SIGKILL)
                killed = true
            }
        }
        if let reason { return .failure(reason) }
        return .success(CommandOutput(status: Self.terminationStatus(status ?? -1), stdout: output[0], stderr: output[1]))
    }

    /// Whether a process the runner can signal is left in the group. Once none is, the group's ID is free and is never
    /// signalled again.
    private func groupAlive(_ pid: pid_t) -> Bool {
        lock.withLock {
            guard !groupGone else { return false }
            if killpg(pid, 0) == 0 { return true }
            groupGone = true
            return false
        }
    }

    private func signal(_ pid: pid_t, _ signal: Int32) {
        lock.withLock { if !groupGone { killpg(pid, signal) } }
    }

    /// Reads at most one chunk of `fd` into its stream's output; `open` is `false` at the end of the output. It keeps
    /// no more than one byte past `limit` in all, which is enough to tell the output is too large; output past that or
    /// past a stop is read and dropped.
    private func read(_ fd: Int32, into output: inout [Data], outFD: Int32, keeping: Bool) -> (open: Bool, count: Int) {
        var buffer = [UInt8](repeating: 0, count: ProcessGroupRunner.chunkSize)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            let room = keeping ? max(0, limit + 1 - output[0].count - output[1].count) : 0
            if room > 0 { output[fd == outFD ? 0 : 1].append(contentsOf: buffer[..<min(count, room)]) }
            return (true, count)
        }
        if count == 0 { return (false, 0) }
        return (errno == EAGAIN || errno == EINTR, 0)
    }

    /// The exit status, or the signal's number for a command a signal ended, as `Process.terminationStatus` gives.
    static func terminationStatus(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : signal
    }

    /// Launches the command in a new process group, without a shell, with standard input from `/dev/null`, default
    /// signal handling, and only its standard input, output, and error open.
    private static func spawn(_ executable: String, arguments: [String], environment: [String: String])
        -> Result<(pid: pid_t, stdout: Int32, stderr: Int32), CommandFailure> {
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { return .failure(.launchFailed(String(cString: strerror(errno)))) }
        guard pipe(&err) == 0 else {
            let error = errno
            out.forEach { close($0) }
            return .failure(.launchFailed(String(cString: strerror(error))))
        }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        for fd in [out[0], err[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                                    | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(out[1])
        close(err[1])
        guard error == 0 else {
            close(out[0])
            close(err[0])
            return .failure(.launchFailed(String(cString: strerror(error))))
        }
        return .success((pid, out[0], err[0]))
    }
}
