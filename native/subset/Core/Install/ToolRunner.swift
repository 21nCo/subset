import Darwin
import Foundation

/// What a tool did: its exit status (nil when it was stopped or ended by a signal), its output and why it was stopped.
struct ToolResult: Sendable {
    var status: Int32?
    var stdout: Data
    var stderr: String

    /// The last line of stderr, for a refusal message.
    var lastLine: String {
        stderr.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "exit \(status.map(String.init) ?? "stopped")"
    }
}

/// Runs a system tool by absolute path, without a shell and with nothing typed into it (hdiutil would otherwise wait for
/// an answer to a licence prompt), as `runTool` in verify.mjs does. The tool runs in its own process group, so it and
/// every process it starts are stopped together: after `timeout`, when it writes more than 1 MiB, or when the calling
/// task is cancelled and `cancellable` is true, the group is sent SIGTERM, then SIGKILL 5 seconds later, and the result
/// has no status. Past 1 MiB nothing more is kept and the output pipes are closed, so a writer that ignores SIGTERM ends
/// on SIGPIPE. A stopped tool settles once its output has ended and its group is empty, or 5 seconds after the
/// SIGKILL, so nothing waits forever. A tool that exits by itself settles when its output ends; when a process it
/// started still holds the output `drainAfterExit` seconds later, the group is stopped the same way. A cancelled call
/// throws CancellationError once the tool has settled; cleanups pass `cancellable: false` so they always finish.
/// `argv0` is the tool's argument zero when it is not its path, such as `-zsh` to start a login shell; `environment`
/// and `directory`, when given, replace this process's environment and working directory. With `ownSession`, the tool
/// leads a session of its own, which every process it starts stays in even in a process group of its own (a job a
/// shell with job control on started) and after the tool exits; stopping it signals every process in that session,
/// and it settles only once they are gone too, or at the same bound. A tool that exits by itself with processes left
/// in its session, even ones holding none of its output, has them stopped `drainAfterExit` seconds later. Only a
/// process that starts a session itself leaves it.
enum ToolRunner {
    static let maxOutputBytes = 1024 * 1024
    static let killAfter: TimeInterval = 5
    static let drainAfterExit: TimeInterval = 2

    static func run(
        _ path: String, _ arguments: [String], argv0: String? = nil, environment: [String: String]? = nil, directory: String? = nil,
        timeout: TimeInterval = 300, cancellable: Bool = true, ownSession: Bool = false
    ) async throws -> ToolResult {
        if cancellable { try Task.checkCancellation() }
        let run = try ToolRun(
            path: path, arguments: arguments, argv0: argv0, environment: environment, directory: directory, timeout: timeout,
            ownSession: ownSession
        )
        let result = await withTaskCancellationHandler {
            await run.result()
        } onCancel: {
            if cancellable { run.stop("cancelled") }
        }
        if cancellable { try Task.checkCancellation() }
        return result
    }

    /// Waits even when the calling task is cancelled (Task.sleep would return at once), so a wait loop that must finish,
    /// such as for a quitting app or a detach, does not spin.
    static func pause(nanoseconds: UInt64) async {
        await Task.detached { try? await Task.sleep(nanoseconds: nanoseconds) }.value
    }
}

/// One running tool, the leader of its own process group. Its state is touched only on `queue`.
private final class ToolRun: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.subset.tool")
    private let pid: pid_t
    private var sources: [DispatchSourceRead] = []
    private var stdout = Data()
    private var stderr = Data()
    /// The output pipes not yet at their end.
    private var open = 2
    /// The wait status once the tool has exited. The tool is reaped only once the result is settled and nothing more is
    /// signalled, so until then its pid and its group's ID stay its own and cannot be reused.
    private var waitStatus: Int32?
    /// Why the tool's exit status could not be read, when waiting for it failed.
    private var waitFailure: String?
    private var stopping: String?
    private var givenUp = false
    private var finished: ToolResult?
    private var continuation: CheckedContinuation<ToolResult, Never>?
    private let ownSession: Bool

    init(
        path: String, arguments: [String], argv0: String?, environment: [String: String]?, directory: String?, timeout: TimeInterval,
        ownSession: Bool
    ) throws {
        self.ownSession = ownSession
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard pipe(&err) == 0 else {
            let code = errno
            close(out[0]); close(out[1])
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        for fd in [out[0], err[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own group (pgid = its pid), or its own session, which also makes it its own group; only stdin, stdout and
        // stderr open, default signal handling and no blocked signals.
        let group = ownSession ? POSIX_SPAWN_SETSID : POSIX_SPAWN_SETPGROUP
        posix_spawnattr_setflags(&attributes, Int16(group | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv: [UnsafeMutablePointer<CChar>?] = ([argv0 ?? path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var child: pid_t = 0
        let code = posix_spawn(&child, path, &actions, &attributes, argv, envp)
        close(out[1])
        close(err[1])
        guard code == 0 else {
            close(out[0]); close(err[0])
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        pid = child

        queue.sync {
            for (fd, isOut) in [(out[0], true), (err[0], false)] {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [unowned self, unowned source] in read(fd, from: source, isOut: isOut) }
                source.setCancelHandler { [self] in
                    close(fd)
                    open -= 1
                    finishIfDone()
                }
                sources.append(source)
                source.resume()
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in stopOnQueue("it did not finish in \(String(format: "%g", timeout)) seconds") }
        }
        // Waits for the tool to exit on its own thread without reaping it (WNOWAIT): it stays a zombie holding its pid and
        // its group's ID until the result is settled (`finishIfDone`), so no signal can reach a reused pid or group.
        Thread { [self, child] in
            var info = siginfo_t()
            var code: Int32 = 0
            repeat { code = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) } while code == -1 && errno == EINTR
            let failure = code == 0 ? nil : String(cString: strerror(errno))
            // As a wait status: the exit code in the second byte, or the signal that ended it.
            let status = info.si_code == CLD_EXITED ? (info.si_status & 0xff) << 8 : info.si_status & 0x7f
            queue.async { [self] in exited(status, failure) }
        }.start()
    }

    func result() async -> ToolResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let finished { continuation.resume(returning: finished) } else { self.continuation = continuation }
            }
        }
    }

    /// Stops the tool's group (any thread).
    func stop(_ reason: String) {
        queue.async { [self] in stopOnQueue(reason) }
    }

    /// One read per event, so the timers and stop requests queued meanwhile run between reads.
    private func read(_ fd: Int32, from source: DispatchSourceRead, isOut: Bool) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var count: Int
        repeat { count = Darwin.read(fd, &buffer, buffer.count) } while count < 0 && errno == EINTR
        if count < 0, errno == EAGAIN { return }
        guard count > 0 else {
            // The end of the output, or an error reading it.
            source.cancel()
            return
        }
        let room = max(0, ToolRunner.maxOutputBytes - stdout.count - stderr.count)
        if isOut { stdout.append(contentsOf: buffer[0..<min(count, room)]) } else { stderr.append(contentsOf: buffer[0..<min(count, room)]) }
        guard count > room else { return }
        // Nothing more is kept: the pipes close (a process still writing gets SIGPIPE) and the group is stopped.
        stopOnQueue("it wrote more than \(ToolRunner.maxOutputBytes) bytes")
        for source in sources where !source.isCancelled { source.cancel() }
    }

    /// The tool has exited (still unreaped); a failed wait leaves no status rather than one that looks like success.
    private func exited(_ status: Int32, _ failure: String?) {
        waitStatus = status
        waitFailure = failure
        guard finished == nil else { return reap() }
        finishIfDone()
        guard finished == nil, stopping == nil else { return }
        // A process the tool started still holds its output or is in its session: it gets a moment to finish, then the
        // group (and session) is stopped.
        queue.asyncAfter(deadline: .now() + ToolRunner.drainAfterExit) { [self] in
            let held = open > 0 ? "held its output" : "ran in its session"
            stopOnQueue("a process it started still \(held) \(Int(ToolRunner.drainAfterExit)) seconds after it exited")
        }
    }

    private func stopOnQueue(_ reason: String) {
        guard finished == nil, stopping == nil else { return }
        stopping = reason
        signal(SIGTERM)
        poll()
        queue.asyncAfter(deadline: .now() + ToolRunner.killAfter) { [self] in
            guard finished == nil else { return }
            signal(SIGKILL)
            queue.asyncAfter(deadline: .now() + ToolRunner.killAfter) { [self] in
                guard finished == nil else { return }
                givenUp = true
                finishIfDone()
            }
        }
    }

    /// Signals the tool's group, even when the tool itself has exited; the tool alone when it left its group. Both stay
    /// its own until it is reaped, which happens only once nothing more is signalled.
    private func signal(_ signal: Int32) {
        if killpg(pid, signal) != 0, waitStatus == nil { kill(pid, signal) }
        // Each process's session is read just before it is signalled; the session's ID is the tool's pid, its own until
        // it is reaped.
        for member in sessionMembers where getsid(member) == pid { kill(member, signal) }
    }

    /// The processes other than the tool in its session, when it leads one.
    private var sessionMembers: [pid_t] {
        guard ownSession else { return [] }
        var all = [pid_t](repeating: 0, count: 8192)
        let count = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
        return all.prefix(Int(max(0, count))).filter { $0 > 0 && $0 != pid && getsid($0) == pid }
    }

    /// Whether no process is left in the tool's group or session besides the exited, unreaped tool (EPERM from killpg
    /// means one is, though it cannot be signalled, or only the unreaped tool is).
    private var groupGone: Bool {
        guard sessionMembers.isEmpty else { return false }
        if killpg(pid, 0) != 0, errno == ESRCH { return true }
        guard waitStatus != nil else { return false }
        var members = [pid_t](repeating: 0, count: 64)
        let count = proc_listpgrppids(pid, &members, Int32(members.count * MemoryLayout<pid_t>.size))
        return count >= 0 && Int(count) < members.count && members.prefix(Int(count)).allSatisfy { $0 == pid }
    }

    /// Reaps the exited tool once its result is settled, releasing its pid and group ID.
    private func reap() {
        guard waitStatus != nil else { return }
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == -1, errno == EINTR {}
    }

    private func poll() {
        finishIfDone()
        guard finished == nil else { return }
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in poll() }
    }

    private func finishIfDone() {
        guard finished == nil else { return }
        let settled: Bool
        if givenUp { settled = true } else if stopping != nil { settled = waitStatus != nil && open == 0 && groupGone } else { settled = waitStatus != nil && open == 0 && sessionMembers.isEmpty }
        guard settled else { return }
        var text = String(decoding: stderr, as: UTF8.self)
        var status: Int32?
        if let waitFailure { text += "\nits exit status could not be read (\(waitFailure))" } else if let waitStatus, stopping == nil {
            // WIFEXITED and WEXITSTATUS, which Swift does not import.
            if waitStatus & 0x7f == 0 { status = (waitStatus >> 8) & 0xff } else { text += "\nended by signal \(waitStatus & 0x7f)" }
        }
        if let stopping { text += "\nstopped: \(stopping)" }
        if givenUp, !(open == 0 && groupGone) { text += "\nstopped: a process it started did not exit" }
        let result = ToolResult(status: status, stdout: stdout, stderr: text)
        finished = result
        reap()
        for source in sources where !source.isCancelled { source.cancel() }
        continuation?.resume(returning: result)
        continuation = nil
    }
}
