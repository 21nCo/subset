import Darwin
import Foundation

/// Fixture doubles for every origin reader, answering from per-PID tables (per-path for launchd) and counting
/// calls. A PID missing from a table answers `unavailable(.processExited)`.
public final class FixtureSignalReaders: ResponsibleProcessReading, CoalitionReading, CodeSignatureReading,
    LaunchdJobReading, ProcessContextReading, @unchecked Sendable {
    public enum Reader: Hashable, Sendable {
        case responsible, coalition, codeSignature, launchd, workingDirectory, terminal
    }

    public var responsible: [pid_t: Signal<Int32>] = [:]
    public var coalitions: [pid_t: Signal<UInt64>] = [:]
    public var signatures: [pid_t: Signal<CodeSignature>] = [:]
    /// Keyed by executable path.
    public var launchdJobs: [String: [LaunchdJob]] = [:]
    public var workingDirectories: [pid_t: Signal<String>] = [:]
    public var terminals: [pid_t: Signal<ControllingTerminal>] = [:]
    /// PIDs that have changed hands by the time the reader checks the identity again.
    public var reusedPIDs: Set<pid_t> = []
    private let lock = NSLock()
    private var calls: [Reader: [pid_t: Int]] = [:]
    private var launchdCalls: [String: Int] = [:]
    public private(set) var refreshes = 0

    public init() {}

    public func calls(_ reader: Reader, pid: pid_t) -> Int { lock.withLock { calls[reader]?[pid] ?? 0 } }
    public func launchdCalls(executable: String) -> Int { lock.withLock { launchdCalls[executable] ?? 0 } }

    /// An `OriginSignalReader` over these fixtures, with a clock that does not move unless one is given.
    public func originReader(now: @escaping @Sendable () -> UInt64 = { 0 }) -> OriginSignalReader {
        OriginSignalReader(
            responsible: self, coalition: self, codeSignature: self, launchd: self, context: self,
            isCurrent: { [self] identity in lock.withLock { !reusedPIDs.contains(identity.pid) } },
            now: now
        )
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

    public func codeSignature(of pid: pid_t, executablePath: String?) -> Signal<CodeSignature> {
        record(.codeSignature, pid)
        return signatures[pid] ?? .unavailable(.processExited, source: .codeSigning)
    }

    public func refreshIfChanged() {
        lock.withLock { refreshes += 1 }
    }

    public func launchdJobs(forExecutable path: String?) -> Signal<[LaunchdJob]> {
        guard let path else { return .unavailable(.noExecutablePath, source: .launchdPlists) }
        lock.withLock { launchdCalls[path, default: 0] += 1 }
        return .value(launchdJobs[path] ?? [], source: .launchdPlists)
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
