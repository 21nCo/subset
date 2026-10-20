import Darwin
import Foundation
import os

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
    /// The calling task was cancelled, so it was stopped or never started.
    case cancelled
}

/// Runs a local executable without a shell.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration) async
        -> Result<CommandOutput, CommandFailure>
}

/// Runs a command with `Process`, reading its output as it arrives so a full pipe never stalls it. At the timeout,
/// once the output passes `outputLimit`, or when the calling task is cancelled, it answers at once and stops the
/// command: `SIGTERM`, then `SIGKILL` a second later if it is still running. A task already cancelled starts nothing.
public struct ProcessCommandRunner: CommandRunning {
    public static let defaultOutputLimit = 8 << 20
    public let outputLimit: Int
    public let registry: CommandRegistry
    let hooks: LaunchHooks

    public init(outputLimit: Int = ProcessCommandRunner.defaultOutputLimit, registry: CommandRegistry = .shared) {
        self.init(outputLimit: outputLimit, registry: registry, hooks: LaunchHooks())
    }

    init(outputLimit: Int = ProcessCommandRunner.defaultOutputLimit, registry: CommandRegistry = .shared, hooks: LaunchHooks) {
        self.outputLimit = outputLimit
        self.registry = registry
        self.hooks = hooks
    }

    public func run(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration) async
        -> Result<CommandOutput, CommandFailure> {
        let run = CommandRun(limit: outputLimit, registry: registry, hooks: hooks)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                run.start(executable, arguments: arguments, environment: environment, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }
}

/// The commands a set of runners has started and not yet seen exit, so an app about to quit can stop them all.
public final class CommandRegistry: Sendable {
    /// The one the app's runners use.
    public static let shared = CommandRegistry()

    private struct State {
        var runs: [ObjectIdentifier: CommandRun] = [:]
        var shutDown = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Before it returns, sends `SIGKILL` to every command already launched and answers each run `cancelled`; a run
    /// not launched yet never launches, and no later run starts. It does not rely on any runner thread, so no child
    /// is left alive when it returns. For an app about to quit, whose delayed `SIGKILL` would never fire, so a
    /// command stuck on a socket would outlive it.
    public func shutDown() {
        let runs = state.withLock { state in
            state.shutDown = true
            return Array(state.runs.values)
        }
        for run in runs { run.killNow() }
    }

    /// Registers a run about to launch, or returns `false` once the registry is shut down.
    fileprivate func register(_ run: CommandRun) -> Bool {
        state.withLock { state in
            guard !state.shutDown else { return false }
            state.runs[ObjectIdentifier(run)] = run
            return true
        }
    }

    fileprivate func remove(_ run: CommandRun) {
        state.withLock { _ = $0.runs.removeValue(forKey: ObjectIdentifier(run)) }
    }
}

/// Test hooks run on either side of the launch, where a shutdown can interleave with it.
struct LaunchHooks: Sendable {
    var beforeLaunch: @Sendable () -> Void = { /* Outside tests nothing waits before the launch. */ }
    var afterLaunch: @Sendable () -> Void = { /* Outside tests nothing waits after the launch. */ }
}

/// One command's run. Every path answers the continuation once; the output handlers and the termination handler
/// keep the run alive until the command has exited and both pipes are closed.
private final class CommandRun: @unchecked Sendable {
    private let lock = NSLock()
    /// Held across `process.run()` and recording the launch, and by `killNow()`, which so finds the command either
    /// not launched, and stops it from launching, or launched with a known pid it kills itself.
    private let launchLock = NSLock()
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let limit: Int
    private var continuation: CheckedContinuation<Result<CommandOutput, CommandFailure>, Never>?
    private var stdout = Data()
    private var stderr = Data()
    private var openPipes = 2
    private var status: Int32?
    private let registry: CommandRegistry
    private let hooks: LaunchHooks
    private var launched = false
    private var cancelled = false
    /// The registry was shut down: the command is killed, or never launches.
    private var killRequested = false
    private var stopping = false

    init(limit: Int, registry: CommandRegistry, hooks: LaunchHooks) {
        self.limit = limit
        self.registry = registry
        self.hooks = hooks
    }

    func start(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration,
               continuation: CheckedContinuation<Result<CommandOutput, CommandFailure>, Never>) {
        let proceed = lock.withLock {
            if !cancelled { self.continuation = continuation }
            return !cancelled
        }
        guard proceed else { return continuation.resume(returning: .failure(.cancelled)) }
        // Registered before the launch, so a command is never running unregistered; removed when it exits.
        guard registry.register(self) else {
            answer(.failure(.cancelled))
            return
        }
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
            registry.remove(self)
            lock.withLock { status = process.terminationStatus }
            finishIfDone()
        }
        hooks.beforeLaunch()
        let launch: Result<Bool, Error> = launchLock.withLock {
            // A shutdown or cancellation that came first has answered already; nothing is launched for it.
            guard !lock.withLock({ killRequested || cancelled }) else { return .success(false) }
            do {
                try process.run()
            } catch {
                return .failure(error)
            }
            lock.withLock { launched = true }
            return .success(true)
        }
        switch launch {
        case .success(true):
            break
        case .success(false):
            abandonLaunch()
            answer(.failure(.cancelled))
            return
        case .failure(let error):
            abandonLaunch()
            answer(.failure(.launchFailed(error.localizedDescription)))
            return
        }
        hooks.afterLaunch()
        // A shutdown after the launch has killed the command itself; a cancellation is stopped here.
        let (killed, cancel) = lock.withLock { (killRequested, cancelled) }
        if killed { return }
        if cancel { stop() }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            if answer(.failure(.timedOut)) { stop() }
        }
    }

    /// Answers `cancelled` and stops the command once it has started.
    func cancel() {
        let started = lock.withLock { cancelled = true; return launched }
        if answer(.failure(.cancelled)), started { stop() }
    }

    /// Answers `cancelled` and, before it returns, sends `SIGKILL` to the command if it has launched, or makes sure
    /// it never launches.
    func killNow() {
        answer(.failure(.cancelled))
        launchLock.withLock {
            let started = lock.withLock {
                cancelled = true
                killRequested = true
                if launched { stopping = true }
                return launched
            }
            guard started else { return }
            stopReading()
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func abandonLaunch() {
        registry.remove(self)
        process.terminationHandler = nil
        stopReading()
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
        guard lock.withLock({ defer { stopping = true }; return !stopping }) else { return }
        stopReading()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
