import Darwin

/// The interface that supplied a signal, or tried to. Every value and every failure names one, so a reader of
/// `ProcessFacts` can tell a private interface's answer from a public one's.
public enum SignalSource: String, Equatable, Sendable, CaseIterable {
    /// The private `responsibility_get_pid_responsible_for_pid`, resolved with `dlsym`.
    case responsibility = "responsibility_get_pid_responsible_for_pid"
    /// The private `PROC_PIDCOALITIONINFO` flavor of `proc_pidinfo`, resolved with `dlsym`.
    case coalitionInfo = "proc_pidinfo(PROC_PIDCOALITIONINFO)"
    /// `SecCodeCopyGuestWithAttributes` and `SecCodeCopySigningInformation`.
    case codeSigning = "SecCodeCopySigningInformation"
    /// The launchd plists in the LaunchAgents and LaunchDaemons folders and installed app bundles.
    case launchdPlists = "launchd plists"
    case vnodePathInfo = "proc_pidinfo(PROC_PIDVNODEPATHINFO)"
    case bsdInfo = "proc_pidinfo(PROC_PIDTBSDINFO)"
    /// The process table (`sysctl` `KERN_PROC_PID`), which macOS lets any user read.
    case processTable = "sysctl(KERN_PROC_PID)"
}

/// Why a reader has no value for a process.
public enum SignalFailure: Equatable, Sendable {
    /// A private symbol is not in this macOS.
    case symbolMissing(String)
    /// macOS refused the read (`EPERM`), typically for another user's process.
    case denied
    /// The process exited, or its PID changed hands, while it was read.
    case processExited
    /// The call failed with this `errno`.
    case systemError(Int32)
    /// A Security framework call failed with this `OSStatus`.
    case securityError(Int32)
    /// The kernel has no executable path for the process, so there is nothing to look up.
    case noExecutablePath
    /// The call succeeded but its result cannot be used.
    case unexpectedResult(String)

    /// Maps the `errno` a failed process read left.
    public init(errno code: Int32) {
        switch code {
        case EPERM: self = .denied
        case ESRCH: self = .processExited
        default: self = .systemError(code)
        }
    }

    public var reason: String {
        switch self {
        case let .symbolMissing(name): "\(name) is not available in this macOS"
        case .denied: "macOS denied the read"
        case .processExited: "the process exited while it was read"
        case let .systemError(code): "failed: \(String(cString: strerror(code))) (errno \(code))"
        case let .securityError(status): "Security framework error \(status)"
        case .noExecutablePath: "the process has no executable path"
        case let .unexpectedResult(detail): detail
        }
    }
}

/// One origin signal: a value, or the reason there is none, with the interface that supplied it either way.
public enum Signal<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value, source: SignalSource)
    case unavailable(SignalFailure, source: SignalSource)

    public var value: Value? {
        if case let .value(value, _) = self { return value }
        return nil
    }

    public var failure: SignalFailure? {
        if case let .unavailable(failure, _) = self { return failure }
        return nil
    }

    public var source: SignalSource {
        switch self {
        case let .value(_, source), let .unavailable(_, source): source
        }
    }
}

/// What the code signature of a process's executable says.
public struct CodeSignature: Equatable, Sendable {
    /// `kSecCodeInfoIdentifier`; `nil` for unsigned code.
    public let signingID: String?
    /// `kSecCodeInfoTeamIdentifier`; `nil` for unsigned, ad-hoc, and Apple platform code.
    public let teamID: String?
    /// A nonzero `kSecCodeInfoPlatformIdentifier`: Apple signed the code as part of macOS.
    public let isPlatformBinary: Bool

    public init(signingID: String?, teamID: String?, isPlatformBinary: Bool) {
        self.signingID = signingID
        self.teamID = teamID
        self.isPlatformBinary = isPlatformBinary
    }

    public var isSigned: Bool { signingID != nil }
}

/// Where a launchd plist was found, which tells who installed the job and who launchd runs it as.
public enum LaunchdDomain: Equatable, Hashable, Sendable {
    /// `~/Library/LaunchAgents`
    case userAgent
    /// `/Library/LaunchAgents`
    case globalAgent
    /// `/Library/LaunchDaemons`
    case globalDaemon
    /// `Contents/Library/LaunchAgents` inside the app bundle at this path.
    case appBundleAgent(bundlePath: String)
}

/// One launchd job plist.
public struct LaunchdJob: Equatable, Hashable, Sendable {
    public let label: String
    public let plistPath: String
    public let domain: LaunchdDomain
    /// `Program`, else `ProgramArguments[0]`, else (in an app bundle) `BundleProgram`, as the plist writes it.
    public let program: String
    /// The program with symlinks resolved, the path the kernel reports for the running process; `nil` when orphaned.
    public let resolvedProgram: String?

    public init(label: String, plistPath: String, domain: LaunchdDomain, program: String, resolvedProgram: String?) {
        self.label = label
        self.plistPath = plistPath
        self.domain = domain
        self.program = program
        self.resolvedProgram = resolvedProgram
    }

    /// The program no longer exists, so launchd cannot start this job.
    public var orphaned: Bool { resolvedProgram == nil }
}

/// A process's controlling terminal, from its `e_tdev`.
public enum ControllingTerminal: Equatable, Sendable {
    /// No controlling terminal (`NODEV`): an app, agent, or daemon rather than a shell session.
    case none
    /// The device name under `/dev`, such as `ttys003`.
    case device(String)
}

/// Every origin signal for one process identity. A restricted process keeps the signals whose readers succeeded;
/// each of the others records why it has none.
public struct OriginSignals: Equatable, Sendable {
    /// The process macOS holds responsible for this one, such as the app that launched a helper.
    public var responsibleProcess: Signal<Int32>
    /// The resource coalition, which macOS shares between an app and the XPC services and helpers it launches.
    public var coalition: Signal<UInt64>
    public var codeSignature: Signal<CodeSignature>
    /// The launchd jobs whose program is this process's executable; empty when no plist names it.
    public var launchdJobs: Signal<[LaunchdJob]>
    public var workingDirectory: Signal<String>
    public var terminal: Signal<ControllingTerminal>

    public init(
        responsibleProcess: Signal<Int32>,
        coalition: Signal<UInt64>,
        codeSignature: Signal<CodeSignature>,
        launchdJobs: Signal<[LaunchdJob]>,
        workingDirectory: Signal<String>,
        terminal: Signal<ControllingTerminal>
    ) {
        self.responsibleProcess = responsibleProcess
        self.coalition = coalition
        self.codeSignature = codeSignature
        self.launchdJobs = launchdJobs
        self.workingDirectory = workingDirectory
        self.terminal = terminal
    }

    /// Every signal unavailable for the same reason, each still naming its reader.
    static func unavailable(_ failure: SignalFailure) -> OriginSignals {
        OriginSignals(
            responsibleProcess: .unavailable(failure, source: .responsibility),
            coalition: .unavailable(failure, source: .coalitionInfo),
            codeSignature: .unavailable(failure, source: .codeSigning),
            launchdJobs: .unavailable(failure, source: .launchdPlists),
            workingDirectory: .unavailable(failure, source: .vnodePathInfo),
            terminal: .unavailable(failure, source: .bsdInfo)
        )
    }
}
