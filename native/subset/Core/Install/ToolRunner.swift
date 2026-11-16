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
/// has no status. A stopped tool settles once its output has ended and its group is empty, or 5 seconds after the
/// SIGKILL, so nothing waits forever. A tool that exits by itself settles when its output ends; when a process it
/// started still holds the output `drainAfterExit` seconds later, the group is stopped the same way. A cancelled call
/// throws CancellationError once the tool has settled; cleanups pass `cancellable: false` so they always finish.
enum ToolRunner {
    static let maxOutputBytes = 1024 * 1024
    static let killAfter: TimeInterval = 5
    static let drainAfterExit: TimeInterval = 2

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 300, cancellable: Bool = true) async throws -> ToolResult {
        if cancellable { try Task.checkCancellation() }
        let run = try ToolRun(path: path, arguments: arguments, timeout: timeout)
        let result = await withTaskCancellationHandler {
            await run.result()
        } onCancel: {
            if cancellable { run.stop("cancelled") }
        }
        if cancellable { try Task.checkCancellation() }
        return result
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
    /// The wait status once the tool has exited and been reaped.
    private var waitStatus: Int32?
    private var stopping: String?
    private var givenUp = false
    private var finished: ToolResult?
    private var continuation: CheckedContinuation<ToolResult, Never>?

    init(path: String, arguments: [String], timeout: TimeInterval) throws {
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
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own group (pgid = its pid), only stdin, stdout and stderr open, default signal handling and no blocked signals.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
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
        // Reaps the tool; a blocking wait on its own thread, as Process does.
        Thread { [self, child] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1, errno == EINTR {}
            queue.async { [self] in exited(status) }
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

    private func read(_ fd: Int32, from source: DispatchSourceRead, isOut: Bool) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if isOut { stdout.append(contentsOf: buffer[0..<count]) } else { stderr.append(contentsOf: buffer[0..<count]) }
                if stdout.count + stderr.count > ToolRunner.maxOutputBytes {
                    stopOnQueue("it wrote more than \(ToolRunner.maxOutputBytes) bytes")
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            // The end of the output, or an error reading it.
            source.cancel()
            return
        }
    }

    private func exited(_ status: Int32) {
        waitStatus = status
        finishIfDone()
        guard finished == nil, stopping == nil else { return }
        // A process the tool started still holds its output: it gets a moment to finish, then the group is stopped.
        queue.asyncAfter(deadline: .now() + ToolRunner.drainAfterExit) { [self] in
            stopOnQueue("a process it started still held its output \(Int(ToolRunner.drainAfterExit)) seconds after it exited")
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

    /// Signals the tool's group, even when the tool itself has exited; the tool alone when it left its group.
    private func signal(_ signal: Int32) {
        if killpg(pid, signal) != 0, waitStatus == nil { kill(pid, signal) }
    }

    /// Whether no process is left in the tool's group (EPERM means one is, though it cannot be signalled).
    private var groupGone: Bool { killpg(pid, 0) != 0 && errno == ESRCH }

    private func poll() {
        finishIfDone()
        guard finished == nil else { return }
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in poll() }
    }

    private func finishIfDone() {
        guard finished == nil else { return }
        let settled: Bool
        if givenUp { settled = true } else if stopping != nil { settled = waitStatus != nil && open == 0 && groupGone } else { settled = waitStatus != nil && open == 0 }
        guard settled else { return }
        var text = String(decoding: stderr, as: UTF8.self)
        var status: Int32?
        if let waitStatus, stopping == nil {
            // WIFEXITED and WEXITSTATUS, which Swift does not import.
            if waitStatus & 0x7f == 0 { status = (waitStatus >> 8) & 0xff } else { text += "\nended by signal \(waitStatus & 0x7f)" }
        }
        if let stopping { text += "\nstopped: \(stopping)" }
        if givenUp, !(open == 0 && groupGone) { text += "\nstopped: a process it started did not exit" }
        let result = ToolResult(status: status, stdout: stdout, stderr: text)
        finished = result
        for source in sources where !source.isCancelled { source.cancel() }
        continuation?.resume(returning: result)
        continuation = nil
    }
}
