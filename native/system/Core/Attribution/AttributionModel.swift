/// The four ways processes are grouped. `Attribution` places every process in exactly one group of each.
public enum AttributionLayer: String, CaseIterable, Sendable {
    /// What the process belongs to: an app, macOS, a coding agent, a terminal, a Homebrew formula, a team.
    case app
    /// Who signed the executable.
    case vendor
    /// What started the process.
    case launchSource
    /// The project its working directory belongs to.
    case project
}

/// How a placement was reached, so the UI can say how far to trust it.
public enum AttributionConfidence: String, Equatable, Sendable {
    /// A fixed rule over the executable path, the parent chain, or names.
    case rule
    /// A signal macOS reported: the responsible process, the coalition, a launchd job, or the code signature.
    case signal
    /// Nothing identified an origin.
    case fallback
}

/// The App layer's closed rule set, in precedence order: the first rule that matches places the process. Later
/// rules that also match are recorded as conflicts and never change the placement.
public enum AppRule: Int, CaseIterable, Comparable, Sendable {
    /// The executable is inside an outermost `*.app` bundle: the app itself, its helpers, XPC services, and login
    /// items.
    case appBundle = 1
    /// An Apple platform binary under `/System`, `/usr/libexec`, `/usr/sbin`, `/usr/bin`, or `/sbin`.
    case macOS
    /// A container VM process, recognized by the hook SET-43 provides; never matches without it.
    case containerVM
    /// The process or an ancestor runs a coding agent (`AttributionNames.codingAgents`).
    case codingAgent
    /// An ancestor is a known terminal app (`AttributionNames.terminals`).
    case terminalSession
    /// The responsible process, or else the coalition's leader, runs inside an app bundle.
    case responsibleProcess
    /// launchd's job for the process names its owning app or its executable's Team ID.
    case launchdJob
    /// The executable is under `/opt/homebrew` or `/usr/local/Cellar`.
    case homebrew
    /// The executable's signature has a Team ID.
    case signingTeam
    /// Nothing above matched.
    case unattributed

    public var confidence: AttributionConfidence {
        switch self {
        // SET-42 leaves the container VM rule's confidence open; its recognizer is a fixed rule like the others.
        case .appBundle, .macOS, .containerVM, .codingAgent, .terminalSession, .homebrew: .rule
        case .responsibleProcess, .launchdJob, .signingTeam: .signal
        case .unattributed: .fallback
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How the Vendor layer placed a process.
public enum VendorRule: Equatable, Sendable {
    case platformBinary, teamID, unsigned, signatureUnavailable

    public var confidence: AttributionConfidence { self == .signatureUnavailable ? .fallback : .signal }
}

/// How the Launch source layer placed a process. The first that applies wins: a coding agent, a terminal session,
/// then the nearest of the process and its ancestors that has a launchd job, is a login item, is or was started by
/// an app, or was started by launchd.
public enum LaunchSourceRule: Equatable, Sendable {
    case codingAgent, terminalSession, launchdJob, loginItem, appLaunched, startedByLaunchd
    /// The chain of parents ends at a process that is not in the sample, so what started it is not known.
    case parentNotSampled

    public var confidence: AttributionConfidence {
        switch self {
        case .codingAgent, .terminalSession, .loginItem, .appLaunched, .startedByLaunchd: .rule
        case .launchdJob: .signal
        case .parentNotSampled: .fallback
        }
    }
}

/// How the Project layer placed a process.
public enum ProjectRule: Equatable, Sendable {
    /// The nearest folder at or above the working directory holding a project marker.
    case marker
    /// No folder holds a marker, so the working directory itself.
    case workingDirectory
    /// The working directory is unavailable, not read yet, or `/`.
    case none

    public var confidence: AttributionConfidence {
        switch self {
        case .marker: .rule
        case .workingDirectory: .signal
        case .none: .fallback
        }
    }
}

/// What a group stands for. Each case belongs to one layer, and its values are paths, labels, and names, never PIDs,
/// so the same origin has the same identity in every sample.
public enum Origin: Hashable, Sendable {
    // App layer
    /// An app, by its outermost bundle's path.
    case app(bundlePath: String)
    case macOS
    case containerVM(name: String)
    /// "Agent: <name>".
    case agent(name: String)
    /// Every terminal session, whichever terminal app runs it.
    case terminal
    /// "Homebrew: <formula>"; `nil` when the path does not name one.
    case homebrew(formula: String?)
    /// A signing team, by Team ID.
    case team(id: String)
    /// The executable path, or the process name when the kernel has no path.
    case unattributed(executable: String)

    // Vendor layer
    case apple
    case vendor(teamID: String)
    /// Unsigned or ad hoc signed: no Team ID and not an Apple platform binary.
    case unsigned
    /// The signature could not be read, or has not been yet; never reported as unsigned.
    case signatureUnavailable

    // Launch source layer
    case launchdJob(label: String)
    /// A login item inside this app bundle.
    case loginItem(bundlePath: String)
    case codingAgentSession(name: String)
    case terminalSession
    case appLaunched
    case system

    // Project layer
    case project(path: String)
    case noProject

    public var layer: AttributionLayer {
        switch self {
        case .app, .macOS, .containerVM, .agent, .terminal, .homebrew, .team, .unattributed: .app
        case .apple, .vendor, .unsigned, .signatureUnavailable: .vendor
        case .launchdJob, .loginItem, .codingAgentSession, .terminalSession, .appLaunched, .system: .launchSource
        case .project, .noProject: .project
        }
    }

    /// A stable text form, used to order groups.
    var key: String {
        switch self {
        case let .app(path): "app:\(path)"
        case .macOS: "macOS"
        case let .containerVM(name): "containerVM:\(name)"
        case let .agent(name): "agent:\(name)"
        case .terminal: "terminal"
        case let .homebrew(formula): "homebrew:\(formula ?? "")"
        case let .team(id): "team:\(id)"
        case let .unattributed(executable): "unattributed:\(executable)"
        case .apple: "apple"
        case let .vendor(teamID): "vendor:\(teamID)"
        case .unsigned: "unsigned"
        case .signatureUnavailable: "signatureUnavailable"
        case let .launchdJob(label): "launchdJob:\(label)"
        case let .loginItem(path): "loginItem:\(path)"
        case let .codingAgentSession(name): "codingAgentSession:\(name)"
        case .terminalSession: "terminalSession"
        case .appLaunched: "appLaunched"
        case .system: "system"
        case let .project(path): "project:\(path)"
        case .noProject: "noProject"
        }
    }
}

/// A group's identity: its origin and, for a subgroup, the subgroup key (a launchd label under macOS, a project path
/// under an agent or the terminal). Equal in every sample for the same origin, so the UI can keep expansion and
/// selection.
public struct OriginGroupID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let origin: Origin
    public let subgroup: String?

    public init(_ origin: Origin, subgroup: String? = nil) {
        self.origin = origin
        self.subgroup = subgroup
    }

    public var layer: AttributionLayer { origin.layer }
    /// The top-level group this one belongs to; itself when it is not a subgroup.
    public var parent: OriginGroupID { OriginGroupID(origin) }
    public var description: String { subgroup.map { "\(origin.key)/\($0)" } ?? origin.key }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.layer.sortIndex, lhs.origin.key, lhs.subgroup ?? "") < (rhs.layer.sortIndex, rhs.origin.key, rhs.subgroup ?? "")
    }
}

extension AttributionLayer {
    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One observation behind a placement or a conflict.
public enum AttributionEvidence: Equatable, Sendable {
    /// The executable path the kernel reported (`nil` when it has none) and the process name.
    case executable(path: String?, name: String)
    /// The outermost app bundle holding the executable.
    case appBundle(path: String)
    /// The executable is under this system location. `platformBinary` is the signature's answer, `nil` when the
    /// signature is unavailable; the sealed system volume holds only Apple's files.
    case systemLocation(prefix: String, platformBinary: Bool?)
    case containerVM(ContainerVM)
    /// The process (`pid` is its own) or an ancestor runs this coding agent.
    case codingAgent(name: String, pid: Int32)
    /// An ancestor runs this terminal app.
    case terminalApp(name: String, pid: Int32, bundlePath: String)
    /// The process's controlling terminal, which an editor's integrated terminal requires.
    case controllingTerminal(device: String)
    /// The process macOS holds responsible, and the app bundle it runs in.
    case responsibleProcess(pid: Int32, bundlePath: String)
    /// The earliest-started member of the process's coalition, and the app bundle it runs in.
    case coalitionLeader(coalition: UInt64, pid: Int32, bundlePath: String)
    /// A launchd job plist for the process's job.
    case launchdJob(LaunchdJob)
    /// A plist with the process's job label whose program no longer exists (`LaunchdJob.orphaned`).
    case orphanedLaunchdJob(LaunchdJob)
    case homebrew(formula: String?)
    case signature(CodeSignature)
    /// The signature is unavailable for this reason, or `nil` when it has not been read yet.
    case signatureUnavailable(SignalFailure?)
    /// The executable is a login item inside this app bundle.
    case loginItem(bundlePath: String)
    /// The process's parent is launchd (pid 1), or the process is launchd or the kernel.
    case parentIsLaunchd
    /// The process inherits its launch source from this ancestor.
    case inheritedFrom(pid: Int32)
    /// The parent with this PID is not in the sample.
    case parentNotSampled(ppid: Int32)
    case workingDirectory(String)
    /// The working directory is unavailable for this reason, or `nil` when it has not been read yet.
    case workingDirectoryUnavailable(SignalFailure?)
    /// The project marker found, and the folder holding it.
    case projectMarker(directory: String, marker: String)
}

/// A later App rule that also matched and points at another group. Recorded so the UI can show the disagreement;
/// it never changes the placement.
public struct AttributionConflict: Equatable, Sendable {
    public let rule: AppRule
    public let group: OriginGroupID
    public let evidence: [AttributionEvidence]
}

/// Where one layer placed a process, the rule that placed it, how much to trust that, and the evidence used.
public struct Placement<Rule: Equatable & Sendable>: Equatable, Sendable {
    /// The top-level group.
    public let group: OriginGroupID
    /// The subgroup within `group`, when the process falls in one.
    public let subgroup: OriginGroupID?
    public let rule: Rule
    public let confidence: AttributionConfidence
    public let evidence: [AttributionEvidence]
    /// Later rules that matched another group; empty outside the App layer.
    public let conflicts: [AttributionConflict]

    init(_ origin: Origin, subgroup: String? = nil, rule: Rule, confidence: AttributionConfidence,
         evidence: [AttributionEvidence], conflicts: [AttributionConflict] = []) {
        group = OriginGroupID(origin)
        self.subgroup = subgroup.map { OriginGroupID(origin, subgroup: $0) }
        self.rule = rule
        self.confidence = confidence
        self.evidence = evidence
        self.conflicts = conflicts
    }
}

/// Every layer's placement of one process.
public struct ProcessAttribution: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let app: Placement<AppRule>
    public let vendor: Placement<VendorRule>
    public let launchSource: Placement<LaunchSourceRule>
    public let project: Placement<ProjectRule>

    /// The top-level group in `layer`.
    public func group(_ layer: AttributionLayer) -> OriginGroupID {
        switch layer {
        case .app: app.group
        case .vendor: vendor.group
        case .launchSource: launchSource.group
        case .project: project.group
        }
    }

    func subgroup(_ layer: AttributionLayer) -> OriginGroupID? {
        switch layer {
        case .app: app.subgroup
        case .vendor: vendor.subgroup
        case .launchSource: launchSource.subgroup
        case .project: project.subgroup
        }
    }
}

/// A group of processes in one layer, with totals computed from its members.
public struct OriginGroup: Identifiable, Equatable, Sendable {
    public let id: OriginGroupID
    public let name: String
    /// In the order the processes were given.
    public let members: [ProcessIdentity]
    public let totals: GroupTotals
    /// Subgroups, ordered by identity. Members without a subgroup key belong to the group only.
    public let subgroups: [OriginGroup]
}

/// A container VM that SET-43's recognizer found.
public struct ContainerVM: Equatable, Sendable {
    public let name: String
    /// What identified it, for the evidence.
    public let detail: String

    public init(name: String, detail: String) {
        self.name = name
        self.detail = detail
    }
}

/// The hook for App rule 3. SET-43 provides the recognizer; without one, a VM process falls through to the later
/// rules.
public protocol ContainerVMRecognizing: Sendable {
    func containerVM(for process: ProcessFacts) -> ContainerVM?
}

/// The fixed names the rules match. The acceptance set is exactly these; anything else is a later follow-up (SET-61).
public enum AttributionNames {
    /// Rule 4: executable names of coding agents, matched against the process name, the executable's file name,
    /// and the agent folder of a versioned install (`…/claude/versions/2.1.304`).
    public static let codingAgents: Set<String> = ["claude", "codex", "cursor-agent", "droid", "opencode", "amp", "gemini"]

    /// Rule 5: terminal apps, by the file name of their outermost app bundle.
    public static let terminals: [KnownTerminal] = [
        KnownTerminal(name: "Terminal", bundleName: "Terminal.app"),
        KnownTerminal(name: "iTerm2", bundleName: "iTerm.app"),
        KnownTerminal(name: "Ghostty", bundleName: "Ghostty.app"),
        KnownTerminal(name: "Warp", bundleName: "Warp.app"),
        KnownTerminal(name: "WezTerm", bundleName: "WezTerm.app"),
        KnownTerminal(name: "kitty", bundleName: "kitty.app"),
        KnownTerminal(name: "Alacritty", bundleName: "Alacritty.app"),
        KnownTerminal(name: "VS Code", bundleName: "Visual Studio Code.app", isEditor: true),
        KnownTerminal(name: "Cursor", bundleName: "Cursor.app", isEditor: true)
    ]

    /// Rule 2: the sealed system locations.
    public static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/"]

    /// Rule 8: Homebrew's prefixes.
    public static let homebrewPrefixes = ["/opt/homebrew/", "/usr/local/Cellar/"]

    /// Project markers, looked for in this order.
    public static let projectMarkers = [".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "Package.swift", "Gemfile", "pom.xml"]
}

/// A terminal app rule 5 recognizes.
public struct KnownTerminal: Equatable, Sendable {
    public let name: String
    public let bundleName: String
    /// An editor (VS Code, Cursor) also starts language servers and other tools outside its bundle; only a process
    /// with a controlling terminal is in its integrated terminal.
    public let isEditor: Bool

    public init(name: String, bundleName: String, isEditor: Bool = false) {
        self.name = name
        self.bundleName = bundleName
        self.isEditor = isEditor
    }
}
