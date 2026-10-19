import Darwin
import Foundation

/// Reads every origin signal for each new process identity once, keeps the result while the identity is alive, and
/// stores it in the process's `ProcessFacts.origin`. Each reader is independent: one that fails records its reason
/// and the others still answer, so a restricted process keeps the signals macOS allows.
///
/// `exec` replaces a process's executable but keeps its PID and start time, so the signals are kept per identity and
/// executable path: an identity that reappears running another executable is read again.
///
/// The readers are keyed by PID alone, so the process is checked again afterwards. If the PID changed hands
/// meanwhile, the signals may describe the later process: they are dropped and the identity, which has exited,
/// records `processExited` for every signal. If the process ran `exec` meanwhile, the signals may mix the two
/// executables: they are dropped and the process is read again, as its new executable, in a later sample.
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
    private let check: @Sendable (ProcessIdentity, String?) -> ProcessImageCheck
    /// Uptime in nanoseconds, replaceable in tests.
    private let now: @Sendable () -> UInt64
    private let lock = NSLock()
    private var cache: [ProcessIdentity: (executablePath: String?, signals: OriginSignals)] = [:]

    public init(
        responsible: any ResponsibleProcessReading,
        coalition: any CoalitionReading,
        codeSignature: any CodeSignatureReading,
        launchd: any LaunchdJobReading,
        context: any ProcessContextReading,
        check: @escaping @Sendable (ProcessIdentity, String?) -> ProcessImageCheck,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.responsible = responsible
        self.coalition = coalition
        self.codeSignature = codeSignature
        self.launchd = launchd
        self.context = context
        self.check = check
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
            check: LibprocProcessSource.check
        )
    }

    /// Fills `origin` for every process already read with its current executable, reads the others, oldest first,
    /// until `budget` is spent (always at least one), and forgets identities no longer listed.
    public func annotate(_ processes: inout [ProcessFacts], budget: Duration = .seconds(1)) {
        let known = lock.withLock { cache }
        var next: [ProcessIdentity: (executablePath: String?, signals: OriginSignals)] = [:]
        next.reserveCapacity(processes.count)
        var unread: [Int] = []
        for index in processes.indices {
            let identity = processes[index].identity
            if let entry = known[identity], entry.executablePath == processes[index].executablePath {
                next[identity] = entry
                processes[index].origin = entry.signals
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
                let executablePath = processes[index].executablePath
                if let entry = next[identity], entry.executablePath == executablePath {
                    processes[index].origin = entry.signals
                    continue
                }
                switch read(identity, executablePath: executablePath) {
                case let .read(signals):
                    next[identity] = (executablePath, signals)
                    processes[index].origin = signals
                case .exited:
                    processes[index].origin = .unavailable(.processExited)
                case .executableChanged:
                    // Not read yet: the next sample lists the new executable and reads it.
                    processes[index].origin = nil
                }
            }
        }
        lock.withLock { cache = next }
    }

    private enum Outcome {
        case read(OriginSignals)
        case exited
        case executableChanged
    }

    /// Every signal for one process, unless its PID changed hands or it ran another executable during the reads.
    private func read(_ identity: ProcessIdentity, executablePath: String?) -> Outcome {
        let pid = identity.pid
        let signals = OriginSignals(
            responsibleProcess: responsible.responsibleProcess(of: pid),
            coalition: coalition.coalition(of: pid),
            codeSignature: codeSignature.codeSignature(of: identity, executablePath: executablePath),
            launchdJobs: launchd.launchdJobs(forExecutable: executablePath),
            workingDirectory: context.workingDirectory(of: pid),
            terminal: context.terminal(of: pid)
        )
        switch check(identity, executablePath) {
        case .unchanged: return .read(signals)
        case .exited: return .exited
        case .executableChanged: return .executableChanged
        }
    }
}

/// What a PID runs now, compared with the identity and executable path a PID-keyed read was for.
public enum ProcessImageCheck: Sendable, Equatable {
    /// The same process still runs the same executable, so the read describes it.
    case unchanged
    /// The process exited; its PID may belong to another process.
    case exited
    /// The same process ran `exec`, which keeps the PID and start time but replaces the executable.
    case executableChanged
}
