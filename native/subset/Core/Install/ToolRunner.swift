import Darwin
import Foundation

/// What a tool did: its exit status (nil when it was stopped), its output and why it was stopped.
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
/// an answer to a licence prompt), as `runTool` in verify.mjs does. A tool that runs longer than `timeout` or writes more
/// than 1 MiB is sent SIGTERM, then SIGKILL 5 seconds later, and its result has no status. When the calling task is
/// cancelled and `cancellable` is true the tool is stopped the same way, and once it has exited the call throws
/// CancellationError; cleanups pass `cancellable: false` so they always finish.
enum ToolRunner {
    static let maxOutputBytes = 1024 * 1024
    static let killAfter: TimeInterval = 5

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 300, cancellable: Bool = true) async throws -> ToolResult {
        if cancellable { try Task.checkCancellation() }
        let run = ToolRun(path: path, arguments: arguments)
        let result = try await withTaskCancellationHandler {
            try await run.start(timeout: timeout)
        } onCancel: {
            if cancellable { run.stop() }
        }
        if cancellable { try Task.checkCancellation() }
        return result
    }
}

/// One running tool. Its state is guarded by `lock`.
private final class ToolRun: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stopped = false

    init(path: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
    }

    func start(timeout: TimeInterval) async throws -> ToolResult {
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async { [self] in
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    let over = lock.withLock { () -> Bool in
                        if isOut { stdout.append(chunk) } else { stderr.append(chunk) }
                        return stdout.count + stderr.count > ToolRunner.maxOutputBytes
                    }
                    if over { stop() }
                }
                group.leave()
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [self] process in
                group.notify(queue: .global()) { [self] in
                    let result = lock.withLock {
                        ToolResult(
                            status: stopped ? nil : process.terminationStatus, stdout: stdout,
                            stderr: String(decoding: stderr, as: UTF8.self) + (stopped ? "\nstopped" : "")
                        )
                    }
                    continuation.resume(returning: result)
                }
            }
            do {
                try process.run()
            } catch {
                out.fileHandleForWriting.closeFile()
                err.fileHandleForWriting.closeFile()
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in stop() }
        }
    }

    /// SIGTERM now and SIGKILL 5 seconds later, while the tool still runs.
    func stop() {
        let pid: pid_t? = lock.withLock {
            guard process.isRunning, !stopped else { return nil }
            stopped = true
            return process.processIdentifier
        }
        guard let pid else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + ToolRunner.killAfter) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
