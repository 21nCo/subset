import Darwin
import Foundation

/// Reads every origin signal for each new process identity once, keeps the result while the identity is alive, and
/// stores it in the process's `ProcessFacts.origin`. Each reader is independent: one that fails records its reason
/// and the others still answer, so a restricted process keeps the signals macOS allows.
///
/// The readers are keyed by PID alone, so the identity is read again afterwards. If the PID changed hands meanwhile,
/// the signals may describe the later process: they are dropped and the identity, which has exited, records
/// `processExited` for every signal.
///
/// Reading every process on a Mac that just started the app takes seconds, mostly in the Security framework, so one
/// call reads new identities only until its time budget is spent. The rest keep `origin == nil` (not read yet) and
/// are read by later calls, oldest first.
public final class OriginSignalReader: @unchecked Sendable {
    private let responsible: any ResponsibleProcessReading
    private let coalition: any CoalitionReading
    private let codeSignature: any CodeSignatureReading
    private let launchd: any LaunchdJobReading
    private let context: any ProcessContextReading
    private let isCurrent: @Sendable (ProcessIdentity) -> Bool
    /// Uptime in nanoseconds, replaceable in tests.
    private let now: @Sendable () -> UInt64
    private let lock = NSLock()
    private var cache: [ProcessIdentity: OriginSignals] = [:]

    public init(
        responsible: any ResponsibleProcessReading,
        coalition: any CoalitionReading,
        codeSignature: any CodeSignatureReading,
        launchd: any LaunchdJobReading,
        context: any ProcessContextReading,
        isCurrent: @escaping @Sendable (ProcessIdentity) -> Bool,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.responsible = responsible
        self.coalition = coalition
        self.codeSignature = codeSignature
        self.launchd = launchd
        self.context = context
        self.isCurrent = isCurrent
        self.now = now
    }

    /// Reads this Mac.
    public static func live() -> OriginSignalReader {
        OriginSignalReader(
            responsible: LiveResponsibleProcessReader(),
            coalition: LiveCoalitionReader(),
            codeSignature: CachedCodeSignatureReader(),
            launchd: LaunchdJobIndex(),
            context: LiveProcessContextReader(),
            isCurrent: { LibprocProcessSource.currentIdentity(of: $0.pid) == $0 }
        )
    }

    /// Fills `origin` for every process already read, reads new identities, oldest first, until `budget` is spent
    /// (always at least one), and forgets identities no longer listed.
    public func annotate(_ processes: inout [ProcessFacts], budget: Duration = .seconds(1)) {
        let known = lock.withLock { cache }
        var next: [ProcessIdentity: OriginSignals] = [:]
        next.reserveCapacity(processes.count)
        var unread: [Int] = []
        for index in processes.indices {
            let identity = processes[index].identity
            if let signals = known[identity] {
                next[identity] = signals
                processes[index].origin = signals
            } else {
                unread.append(index)
            }
        }
        if !unread.isEmpty {
            launchd.refreshIfChanged()
            let start = now()
            let limit = UInt64(max(0, budget / .nanoseconds(1)))
            // Oldest first, so a process that keeps running is read before short-lived ones that may exit anyway.
            unread.sort { processes[$0].identity.startTime < processes[$1].identity.startTime }
            for (position, index) in unread.enumerated() {
                if position > 0, now() &- start >= limit { break }
                let identity = processes[index].identity
                if let signals = next[identity] {
                    processes[index].origin = signals
                } else if let signals = read(identity, executablePath: processes[index].executablePath) {
                    next[identity] = signals
                    processes[index].origin = signals
                } else {
                    processes[index].origin = .unavailable(.processExited)
                }
            }
        }
        lock.withLock { cache = next }
    }

    /// Every signal for one process, or `nil` when its PID changed hands during the reads.
    private func read(_ identity: ProcessIdentity, executablePath: String?) -> OriginSignals? {
        let pid = identity.pid
        let signals = OriginSignals(
            responsibleProcess: responsible.responsibleProcess(of: pid),
            coalition: coalition.coalition(of: pid),
            codeSignature: codeSignature.codeSignature(of: identity, executablePath: executablePath),
            launchdJobs: launchd.launchdJobs(forExecutable: executablePath),
            workingDirectory: context.workingDirectory(of: pid),
            terminal: context.terminal(of: pid)
        )
        return isCurrent(identity) ? signals : nil
    }
}
