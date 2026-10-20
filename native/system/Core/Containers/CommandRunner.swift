import Darwin
import Foundation

/// What a finished command printed and its exit status.
public struct CommandOutput: Equatable, Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandFailure: Error, Equatable, Sendable {
    /// The executable could not be started.
    case launchFailed(String)
    /// It ran past the timeout and was stopped.
    case timedOut
    /// It printed more than the runner keeps, and was stopped.
    case outputTooLarge
}

/// Runs a local executable without a shell.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration) async
        -> Result<CommandOutput, CommandFailure>
}

/// Runs a command with `Process`, reading its output as it arrives so a full pipe never stalls it. At the timeout,
/// or once the output passes `outputLimit`, it answers at once and stops the command: `SIGTERM`, then `SIGKILL` a
/// second later if it is still running.
public struct ProcessCommandRunner: CommandRunning {
    public static let defaultOutputLimit = 8 << 20
    public let outputLimit: Int

    public init(outputLimit: Int = ProcessCommandRunner.defaultOutputLimit) {
        self.outputLimit = outputLimit
    }

    public func run(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration) async
        -> Result<CommandOutput, CommandFailure> {
        await withCheckedContinuation { continuation in
            CommandRun(limit: outputLimit, continuation: continuation)
                .start(executable, arguments: arguments, environment: environment, timeout: timeout)
        }
    }
}

/// One command's run. Every path answers the continuation once; the output handlers and the termination handler
/// keep the run alive until the command has exited and both pipes are closed.
private final class CommandRun: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let limit: Int
    private var continuation: CheckedContinuation<Result<CommandOutput, CommandFailure>, Never>?
    private var stdout = Data()
    private var stderr = Data()
    private var openPipes = 2
    private var status: Int32?

    init(limit: Int, continuation: CheckedContinuation<Result<CommandOutput, CommandFailure>, Never>) {
        self.limit = limit
        self.continuation = continuation
    }

    func start(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] in receive($0.availableData, error: false) }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] in receive($0.availableData, error: true) }
        process.terminationHandler = { [self] process in
            // Clearing the handler releases this run once the pipes are closed too.
            process.terminationHandler = nil
            lock.withLock { status = process.terminationStatus }
            finishIfDone()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            stopReading()
            answer(.failure(.launchFailed(error.localizedDescription)))
            return
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            if answer(.failure(.timedOut)) { stop() }
        }
    }

    private func receive(_ data: Data, error: Bool) {
        guard !data.isEmpty else {
            (error ? stderrPipe : stdoutPipe).fileHandleForReading.readabilityHandler = nil
            lock.withLock { openPipes -= 1 }
            finishIfDone()
            return
        }
        let overLimit = lock.withLock {
            if error { stderr.append(data) } else { stdout.append(data) }
            return stdout.count + stderr.count > limit
        }
        if overLimit, answer(.failure(.outputTooLarge)) { stop() }
    }

    private func finishIfDone() {
        let output: CommandOutput? = lock.withLock {
            guard openPipes == 0, let status else { return nil }
            return CommandOutput(status: status, stdout: stdout, stderr: stderr)
        }
        if let output { answer(.success(output)) }
    }

    /// Answers the continuation, or returns `false` when it was already answered.
    @discardableResult
    private func answer(_ result: Result<CommandOutput, CommandFailure>) -> Bool {
        guard let continuation = lock.withLock({ () -> CheckedContinuation<Result<CommandOutput, CommandFailure>, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }) else { return false }
        continuation.resume(returning: result)
        return true
    }

    private func stopReading() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func stop() {
        stopReading()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
