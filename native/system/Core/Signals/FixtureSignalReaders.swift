import Darwin
import Foundation

/// Fixture doubles for every origin reader, answering from per-PID tables (per-path for launchd) and counting
/// calls. A PID missing from a table answers `unavailable(.processExited)`. Each table is read and written under a
/// lock, so a test may change one while readers run on other threads.
public final class FixtureSignalReaders: ResponsibleProcessReading, CoalitionReading, CodeSignatureReading,
    LaunchdJobReading, ProcessContextReading, @unchecked Sendable {
    public enum Reader: Hashable, Sendable {
        case responsible, coalition, codeSignature, launchd, workingDirectory, terminal
    }

    @Locked public var responsible: [pid_t: Signal<Int32>] = [:]
    @Locked public var coalitions: [pid_t: Signal<UInt64>] = [:]
    @Locked public var signatures: [pid_t: Signal<CodeSignature>] = [:]
    /// Keyed by executable path.
    @Locked public var launchdJobs: [String: [LaunchdJob]] = [:]
    /// Folders and plists the launchd scan could not read. As in `LaunchdJobIndex`, found jobs carry them, and an
    /// executable with no job is then `unavailable(.incompleteScan)`.
    @Locked public var launchdScanFailures: [LaunchdScanFailure] = []
    @Locked public var workingDirectories: [pid_t: Signal<String>] = [:]
    @Locked public var terminals: [pid_t: Signal<ControllingTerminal>] = [:]
    /// PIDs that have changed hands by the time the reader checks the identity again.
    @Locked public var reusedPIDs: Set<pid_t> = []
    /// The executable a PID has run `exec` to by the time the reader checks it again.
    @Locked public var execs: [pid_t: String] = [:]
    private let lock = NSLock()
    private var calls: [Reader: [pid_t: Int]] = [:]
    private var launchdCalls: [String: Int] = [:]
    public private(set) var refreshes = 0
    /// The launchd tables as of the last refresh, which reports a change when they differ.
    private var indexed: (jobs: [String: [LaunchdJob]], failures: [LaunchdScanFailure])?

    public init() {}

    public func calls(_ reader: Reader, pid: pid_t) -> Int { lock.withLock { calls[reader]?[pid] ?? 0 } }
    public func launchdCalls(executable: String) -> Int { lock.withLock { launchdCalls[executable] ?? 0 } }

    /// An `OriginSignalReader` over these fixtures, with a clock that does not move unless one is given.
    public func originReader(now: @escaping @Sendable () -> UInt64 = { 0 }) -> OriginSignalReader {
        OriginSignalReader(
            responsible: self, coalition: self, codeSignature: self, launchd: self, context: self,
            check: { [self] in check($0, executablePath: $1) },
            now: now
        )
    }

    /// Answers from `reusedPIDs` and `execs`; any other process still runs the executable it was read with.
    public func check(_ identity: ProcessIdentity, executablePath: String?) -> ProcessImageCheck {
        lock.withLock {
            if reusedPIDs.contains(identity.pid) { return .exited }
            guard let path = execs[identity.pid] else { return .unchanged }
            return path == executablePath ? .unchanged : .executableChanged
        }
    }

    private func record(_ reader: Reader, _ pid: pid_t) {
        lock.withLock { calls[reader, default: [:]][pid, default: 0] += 1 }
    }

    public func responsibleProcess(of pid: pid_t) -> Signal<Int32> {
        record(.responsible, pid)
        return responsible[pid] ?? .unavailable(.processExited, source: .responsibility)
    }

    public func coalition(of pid: pid_t) -> Signal<UInt64> {
        record(.coalition, pid)
        return coalitions[pid] ?? .unavailable(.processExited, source: .coalitionInfo)
    }

    public func codeSignature(of identity: ProcessIdentity, executablePath: String?) -> Signal<CodeSignature> {
        record(.codeSignature, identity.pid)
        return signatures[identity.pid] ?? .unavailable(.processExited, source: .codeSigning)
    }

    @discardableResult public func refreshIfChanged() -> Bool {
        let current = (jobs: launchdJobs, failures: launchdScanFailures)
        return lock.withLock {
            refreshes += 1
            defer { indexed = current }
            guard let indexed else { return true }
            return indexed.jobs != current.jobs || indexed.failures != current.failures
        }
    }

    public func launchdJobs(forExecutable path: String?) -> Signal<LaunchdJobs> {
        guard let path else { return .unavailable(.noExecutablePath, source: .launchdPlists) }
        lock.withLock { launchdCalls[path, default: 0] += 1 }
        let jobs = launchdJobs[path] ?? []
        let failures = launchdScanFailures
        if jobs.isEmpty, !failures.isEmpty { return .unavailable(.incompleteScan(failures), source: .launchdPlists) }
        return .value(LaunchdJobs(jobs: jobs, scanFailures: failures), source: .launchdPlists)
    }

    public func workingDirectory(of pid: pid_t) -> Signal<String> {
        record(.workingDirectory, pid)
        return workingDirectories[pid] ?? .unavailable(.processExited, source: .vnodePathInfo)
    }

    public func terminal(of pid: pid_t) -> Signal<ControllingTerminal> {
        record(.terminal, pid)
        return terminals[pid] ?? .unavailable(.processExited, source: .bsdInfo)
    }
}

/// A value read and written under its own lock.
@propertyWrapper
public struct Locked<Value>: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private let box: Box

    public init(wrappedValue: Value) {
        box = Box(wrappedValue)
    }

    public var wrappedValue: Value {
        get { box.lock.withLock { box.value } }
        nonmutating set { box.lock.withLock { box.value = newValue } }
    }
}
