/// Places every process of one sample in exactly one group per layer (App, Vendor, Launch source, Project), with the
/// rule, evidence, and confidence behind each placement, and sums each group's usage from its members. Deterministic:
/// the same processes, launchd jobs, and project markers always give the same groups. Ancestor questions are answered
/// for the whole sample at once from a parent index, so a sample costs linear time.
public struct Attribution: Sendable {
    public let projectMarkers: any ProjectMarkerLookup
    public let containerVM: (any ContainerVMRecognizing)?

    public init(projectMarkers: any ProjectMarkerLookup = FileSystemProjectMarkers(),
                containerVM: (any ContainerVMRecognizing)? = nil) {
        self.projectMarkers = projectMarkers
        self.containerVM = containerVM
    }

    /// Attributes `processes`. `launchdJobs` is every indexed job (`LaunchdJobIndex.jobs`), used to flag orphaned
    /// plists that share a running process's job label; a process's own jobs come from its origin signals. A
    /// repeated identity is attributed once.
    public func attribute(_ processes: [ProcessFacts], launchdJobs: [LaunchdJob] = []) -> AttributionResult {
        var seen = Set<ProcessIdentity>()
        let unique = processes.filter { seen.insert($0.identity).inserted }
        let pass = AttributionPass(unique, launchdJobs: launchdJobs, markers: projectMarkers, containerVM: containerVM)
        let attributions = pass.run()
        return AttributionResult(
            processes: unique,
            attributions: attributions,
            orphanedLaunchdJobs: launchdJobs.filter(\.orphaned).sorted { $0.plistPath < $1.plistPath },
            steps: pass.tree.steps
        )
    }
}

/// One sample's attribution.
public struct AttributionResult: Sendable {
    /// One per distinct process, in the order given.
    public let processes: [ProcessAttribution]
    public let app: [OriginGroup]
    public let vendor: [OriginGroup]
    public let launchSource: [OriginGroup]
    public let project: [OriginGroup]
    /// Every indexed launchd job whose program no longer exists, ordered by plist path.
    public let orphanedLaunchdJobs: [LaunchdJob]
    /// Parent links followed and processes tested by the ancestor queries.
    let steps: Int
    private let index: [ProcessIdentity: Int]

    init(processes: [ProcessFacts], attributions: [ProcessAttribution], orphanedLaunchdJobs: [LaunchdJob], steps: Int) {
        self.processes = attributions
        self.orphanedLaunchdJobs = orphanedLaunchdJobs
        self.steps = steps
        index = Dictionary(attributions.enumerated().map { ($1.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let build = { (layer: AttributionLayer) in GroupBuilder.groups(layer, processes: processes, attributions: attributions) }
        app = build(.app)
        vendor = build(.vendor)
        launchSource = build(.launchSource)
        project = build(.project)
    }

    public func groups(_ layer: AttributionLayer) -> [OriginGroup] {
        switch layer {
        case .app: app
        case .vendor: vendor
        case .launchSource: launchSource
        case .project: project
        }
    }

    public func attribution(of identity: ProcessIdentity) -> ProcessAttribution? {
        index[identity].map { processes[$0] }
    }
}

/// A rule that matched, before precedence picks the winner.
private struct Candidate {
    let rule: AppRule
    let origin: Origin
    var subgroup: String?
    let evidence: [AttributionEvidence]
}

/// What the Project layer found for one process.
private struct ProjectFinding {
    let origin: Origin
    let rule: ProjectRule
    let evidence: [AttributionEvidence]

    var path: String? {
        if case let .project(path) = origin { path } else { nil }
    }
}

/// A launch source a process has on its own, before inheritance.
private struct LaunchFinding {
    let origin: Origin
    let rule: LaunchSourceRule
    let evidence: [AttributionEvidence]
}

private final class AttributionPass {
    let tree: ProcessTree
    private let markers: any ProjectMarkerLookup
    private let containerVM: (any ContainerVMRecognizing)?
    private let orphanedByLabel: [String: [LaunchdJob]]
    private var markerCache: [String: (directory: String, marker: String)?] = [:]

    /// Each process's outermost app bundle.
    private let bundles: [String?]
    private let agentNames: [String?]
    private let terminalApps: [KnownTerminal?]
    /// The nearest of each process and its ancestors running a coding agent.
    private var agentAt: [Int?] = []
    /// The nearest strict ancestor running a known terminal app.
    private var terminalAt: [Int?] = []
    /// Each coalition's earliest-started member.
    private var coalitionLeaders: [UInt64: Int] = [:]

    init(_ processes: [ProcessFacts], launchdJobs: [LaunchdJob], markers: any ProjectMarkerLookup,
         containerVM: (any ContainerVMRecognizing)?) {
        tree = ProcessTree(processes)
        self.markers = markers
        self.containerVM = containerVM
        orphanedByLabel = Dictionary(grouping: launchdJobs.filter(\.orphaned), by: \.label)
        bundles = processes.map { $0.executablePath.flatMap(Self.outermostAppBundle) }
        agentNames = processes.map(Self.agentName)
        terminalApps = bundles.map { bundle in
            bundle.flatMap { path in AttributionNames.terminals.first { $0.bundleName == Self.lastComponent(path) } }
        }
    }

    func run() -> [ProcessAttribution] {
        agentAt = tree.nearest { agentNames[$0] != nil }
        terminalAt = tree.nearestAncestor { terminalApps[$0] != nil }
        for (index, process) in tree.processes.enumerated() {
            guard let coalition = process.coalitionID else { continue }
            if let leader = coalitionLeaders[coalition] {
                let current = tree.processes[leader].identity
                if (current.startTime, current.pid) <= (process.identity.startTime, process.pid) { continue }
            }
            coalitionLeaders[coalition] = index
        }
        let ownLaunch = (0..<tree.count).map(ownLaunchSource)
        let launchAt = tree.nearest { ownLaunch[$0] != nil || self.tree.parent[$0] == nil }
        return tree.processes.indices.map { index in
            let process = tree.processes[index]
            let project = project(of: process)
            return ProcessAttribution(
                identity: process.identity,
                app: appPlacement(index, project: project),
                vendor: vendorPlacement(process),
                launchSource: launchPlacement(index, launchAt: launchAt[index], ownLaunch: ownLaunch),
                project: Placement(project.origin, rule: project.rule, confidence: project.rule.confidence, evidence: project.evidence)
            )
        }
    }

    // MARK: App layer

    private func appPlacement(_ index: Int, project: ProjectFinding) -> Placement<AppRule> {
        let candidates = appCandidates(index, project: project)
        let process = tree.processes[index]
        let winner = candidates.first ?? Candidate(
            rule: .unattributed,
            origin: .unattributed(executable: process.executablePath ?? process.name),
            evidence: [.executable(path: process.executablePath, name: process.name), signatureEvidence(process)]
        )
        // Only the signals that name an app or a job can disagree with the winner; a Team ID or Homebrew path that
        // follows an app bundle describes the same code, not another origin.
        let conflicts = candidates.dropFirst()
            .filter { [.responsibleProcess, .launchdJob].contains($0.rule) && $0.origin != winner.origin }
            .map { AttributionConflict(rule: $0.rule, group: OriginGroupID($0.origin, subgroup: $0.subgroup), evidence: $0.evidence) }
        return Placement(winner.origin, subgroup: winner.subgroup, rule: winner.rule, confidence: winner.rule.confidence,
                         evidence: winner.evidence, conflicts: Array(conflicts))
    }

    /// Every App rule from 1 to 9 that matches, in precedence order. Rule 6 may give two: the responsible process,
    /// then the coalition leader.
    private func appCandidates(_ index: Int, project: ProjectFinding) -> [Candidate] {
        let process = tree.processes[index]
        let path = process.executablePath
        var candidates: [Candidate] = []

        if let bundle = bundles[index] {
            candidates.append(Candidate(rule: .appBundle, origin: .app(bundlePath: bundle), evidence: [.appBundle(path: bundle)]))
        }
        if let path, let prefix = AttributionNames.systemPrefixes.first(where: { path.hasPrefix($0) }),
           Self.isPlatformLocation(path, platformBinary: process.isPlatformBinary) {
            let label = process.launchdLabel
            candidates.append(Candidate(
                rule: .macOS, origin: .macOS, subgroup: label,
                evidence: [.systemLocation(prefix: String(prefix.dropLast()), platformBinary: process.isPlatformBinary)]
                    + jobEvidence(process, label: label)
            ))
        }
        if let vm = containerVM?.containerVM(for: process) {
            candidates.append(Candidate(rule: .containerVM, origin: .containerVM(name: vm.name), evidence: [.containerVM(vm)]))
        }
        if let agent = agentAt[index], let name = agentNames[agent] {
            candidates.append(Candidate(rule: .codingAgent, origin: .agent(name: name), subgroup: project.path,
                                        evidence: [.codingAgent(name: name, pid: tree.processes[agent].pid)]))
        }
        if let terminal = terminalSession(index) {
            candidates.append(Candidate(rule: .terminalSession, origin: .terminal, subgroup: project.path, evidence: terminal))
        }
        if let responsible = responsibleApp(index) {
            candidates.append(Candidate(rule: .responsibleProcess, origin: .app(bundlePath: responsible.bundle),
                                        evidence: [.responsibleProcess(pid: responsible.pid, bundlePath: responsible.bundle)]))
        }
        if let coalition = process.coalitionID, let leader = coalitionLeaders[coalition], leader != index,
           let bundle = bundles[leader] {
            candidates.append(Candidate(rule: .responsibleProcess, origin: .app(bundlePath: bundle),
                                        evidence: [.coalitionLeader(coalition: coalition, pid: tree.processes[leader].pid, bundlePath: bundle)]))
        }
        if let label = process.launchdLabel {
            let jobs = process.origin?.launchdJobs.value?.jobs.filter { $0.label == label } ?? []
            let evidence = jobEvidence(process, label: label)
            if let bundle = jobs.lazy.compactMap(Self.appBundleAgentPath).first {
                candidates.append(Candidate(rule: .launchdJob, origin: .app(bundlePath: bundle), evidence: evidence))
            } else if let team = process.teamID, let signature = process.origin?.codeSignature.value {
                candidates.append(Candidate(rule: .launchdJob, origin: .team(id: team), evidence: evidence + [.signature(signature)]))
            }
        }
        if let path, AttributionNames.homebrewPrefixes.contains(where: { path.hasPrefix($0) }) {
            let formula = Self.homebrewFormula(path)
            candidates.append(Candidate(rule: .homebrew, origin: .homebrew(formula: formula), evidence: [.homebrew(formula: formula)]))
        }
        if let team = process.teamID, let signature = process.origin?.codeSignature.value {
            candidates.append(Candidate(rule: .signingTeam, origin: .team(id: team), evidence: [.signature(signature)]))
        }
        return candidates
    }

    /// The job plists with the process's label, and the orphaned plists that share it.
    private func jobEvidence(_ process: ProcessFacts, label: String?) -> [AttributionEvidence] {
        guard let label else { return [] }
        let jobs = process.origin?.launchdJobs.value?.jobs.filter { $0.label == label } ?? []
        return jobs.map(AttributionEvidence.launchdJob) + (orphanedByLabel[label] ?? []).map(AttributionEvidence.orphanedLaunchdJob)
    }

    /// The evidence for a terminal session: the nearest terminal app above the process, and for an editor the
    /// process's controlling terminal, without which it is one of the editor's tools rather than its terminal.
    private func terminalSession(_ index: Int) -> [AttributionEvidence]? {
        guard let terminal = terminalAt[index], let app = terminalApps[terminal], let bundle = bundles[terminal] else { return nil }
        let tty = tree.processes[index].tty
        if app.isEditor, tty == nil { return nil }
        return [.terminalApp(name: app.name, pid: tree.processes[terminal].pid, bundlePath: bundle)]
            + (tty.map { [.controllingTerminal(device: $0)] } ?? [])
    }

    /// The process macOS holds responsible, when it is another sampled process inside an app bundle.
    private func responsibleApp(_ index: Int) -> (pid: Int32, bundle: String)? {
        let process = tree.processes[index]
        guard let pid = process.responsiblePID, pid != process.pid,
              let responsible = tree.index(of: pid, startedBy: process.identity.startTime),
              let bundle = bundles[responsible] else { return nil }
        return (pid, bundle)
    }

    // MARK: Vendor layer

    private func vendorPlacement(_ process: ProcessFacts) -> Placement<VendorRule> {
        let evidence = [signatureEvidence(process)]
        guard let signature = process.origin?.codeSignature.value else {
            return Placement(.signatureUnavailable, rule: .signatureUnavailable, confidence: VendorRule.signatureUnavailable.confidence, evidence: evidence)
        }
        let (origin, rule): (Origin, VendorRule) = if signature.isPlatformBinary {
            (.apple, .platformBinary)
        } else if let team = signature.teamID {
            (.vendor(teamID: team), .teamID)
        } else {
            (.unsigned, .unsigned)
        }
        return Placement(origin, rule: rule, confidence: rule.confidence, evidence: evidence)
    }

    private func signatureEvidence(_ process: ProcessFacts) -> AttributionEvidence {
        switch process.origin?.codeSignature {
        case let .value(signature, _): .signature(signature)
        case let .unavailable(failure, _): .signatureUnavailable(failure)
        case nil: .signatureUnavailable(nil)
        }
    }

    // MARK: Launch source layer

    private func launchPlacement(_ index: Int, launchAt: Int?, ownLaunch: [LaunchFinding?]) -> Placement<LaunchSourceRule> {
        // The process's own agent started it only when it is a child; an agent's own process was started by
        // whatever started the agent.
        if let parent = tree.parent[index], let agent = agentAt[parent], let name = agentNames[agent] {
            return Placement(.codingAgentSession(name: name), rule: .codingAgent, confidence: LaunchSourceRule.codingAgent.confidence,
                             evidence: [.codingAgent(name: name, pid: tree.processes[agent].pid)])
        }
        if let evidence = terminalSession(index) {
            return Placement(.terminalSession, rule: .terminalSession, confidence: LaunchSourceRule.terminalSession.confidence, evidence: evidence)
        }
        let process = tree.processes[index]
        guard let source = launchAt, let found = ownLaunch[source] else {
            let top = launchAt.map { tree.processes[$0] } ?? process
            return Placement(.system, rule: .parentNotSampled, confidence: LaunchSourceRule.parentNotSampled.confidence,
                             evidence: [.parentNotSampled(ppid: top.ppid)])
        }
        let inherited: [AttributionEvidence] = source == index ? [] : [.inheritedFrom(pid: tree.processes[source].pid)]
        return Placement(found.origin, rule: found.rule, confidence: found.rule.confidence, evidence: inherited + found.evidence)
    }

    /// The launch source a process shows by itself: its launchd job, a login item, an app (itself or the
    /// responsible process), or launchd as its parent. `nil` sends the question to its parent.
    private func ownLaunchSource(_ index: Int) -> LaunchFinding? {
        let process = tree.processes[index]
        if let label = process.launchdLabel {
            return LaunchFinding(origin: .launchdJob(label: label), rule: .launchdJob, evidence: jobEvidence(process, label: label))
        }
        if let bundle = bundles[index], let path = process.executablePath, path.hasPrefix(bundle + "/Contents/Library/LoginItems/") {
            return LaunchFinding(origin: .loginItem(bundlePath: bundle), rule: .loginItem, evidence: [.loginItem(bundlePath: bundle)])
        }
        if let bundle = bundles[index] {
            return LaunchFinding(origin: .appLaunched, rule: .appLaunched, evidence: [.appBundle(path: bundle)])
        }
        if let responsible = responsibleApp(index) {
            return LaunchFinding(origin: .appLaunched, rule: .appLaunched,
                                 evidence: [.responsibleProcess(pid: responsible.pid, bundlePath: responsible.bundle)])
        }
        if process.ppid <= 1 || process.pid <= 1 {
            return LaunchFinding(origin: .system, rule: .startedByLaunchd, evidence: [.parentIsLaunchd])
        }
        return nil
    }

    // MARK: Project layer

    private func project(of process: ProcessFacts) -> ProjectFinding {
        guard let signal = process.origin?.workingDirectory else {
            return ProjectFinding(origin: .noProject, rule: .none, evidence: [.workingDirectoryUnavailable(nil)])
        }
        guard let cwd = signal.value else {
            return ProjectFinding(origin: .noProject, rule: .none, evidence: [.workingDirectoryUnavailable(signal.failure)])
        }
        var directory = cwd
        while directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
        // `/` is where launchd starts every job and app; it is no project.
        guard directory.hasPrefix("/"), directory != "/" else {
            return ProjectFinding(origin: .noProject, rule: .none, evidence: [.workingDirectory(cwd)])
        }
        if let hit = marker(atOrAbove: directory) {
            return ProjectFinding(origin: .project(path: hit.directory), rule: .marker,
                                  evidence: [.workingDirectory(cwd), .projectMarker(directory: hit.directory, marker: hit.marker)])
        }
        return ProjectFinding(origin: .project(path: directory), rule: .workingDirectory, evidence: [.workingDirectory(cwd)])
    }

    /// The nearest folder at or above `directory`, below `/`, holding a project marker. Each folder is looked in
    /// at most once per pass.
    private func marker(atOrAbove directory: String) -> (directory: String, marker: String)? {
        var visited: [String] = []
        var current = directory
        var hit: (directory: String, marker: String)?
        while current != "/" {
            if let cached = markerCache[current] { hit = cached; break }
            visited.append(current)
            if let marker = markers.marker(in: current) { hit = (current, marker); break }
            current = Self.parentFolder(current)
        }
        for folder in visited { markerCache[folder] = .some(hit) }
        return hit
    }

    // MARK: Paths and names

    /// The outermost `*.app` bundle the executable is inside: a path component ending in `.app` followed by the
    /// bundle's `Contents` (or an iOS app's `Wrapper`). A folder that merely ends in `.app` is not a bundle.
    static func outermostAppBundle(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for index in parts.indices.dropLast() where parts[index].count > 4 && parts[index].hasSuffix(".app") {
            if parts[index + 1] == "Contents" || parts[index + 1] == "Wrapper" {
                return parts[...index].joined(separator: "/")
            }
        }
        return nil
    }

    /// The coding agent a process runs, by its kernel name or its executable's file name, or by the folder of a
    /// versioned install, `…/<agent>/versions/<version>`: Claude Code's native installer runs
    /// `~/.local/share/claude/versions/2.1.304`, whose kernel name is the version, and the `claude` the user typed is
    /// only in the arguments, which are never read.
    static func agentName(_ process: ProcessFacts) -> String? {
        if AttributionNames.codingAgents.contains(process.name) { return process.name }
        guard let path = process.executablePath else { return nil }
        let parts = path.split(separator: "/").suffix(3).map(String.init)
        if let file = parts.last, AttributionNames.codingAgents.contains(file) { return file }
        if parts.count == 3, parts[1] == "versions", AttributionNames.codingAgents.contains(parts[0]) { return parts[0] }
        return nil
    }

    /// Whether rule 2 may place a binary at this system path: a platform signature anywhere under the rule's
    /// locations, or a signature that is not yet read only outside the writable, unsealed locations among them. A
    /// known non-platform signature never does.
    static func isPlatformLocation(_ path: String, platformBinary: Bool?) -> Bool {
        switch platformBinary {
        case true?: true
        case false?: false
        case nil: !AttributionNames.unsealedSystemPrefixes.contains { path.hasPrefix($0) }
        }
    }

    /// The formula (or cask) a Homebrew path names: `/opt/homebrew/{Cellar,opt,Caskroom}/<name>/…` or
    /// `/usr/local/Cellar/<name>/…`.
    static func homebrewFormula(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.starts(with: ["usr", "local", "Cellar"]), parts.count > 4 { return parts[3] }
        if parts.starts(with: ["opt", "homebrew"]), parts.count > 4, ["Cellar", "opt", "Caskroom"].contains(parts[2]) { return parts[3] }
        return nil
    }

    static func appBundleAgentPath(_ job: LaunchdJob) -> String? {
        if case let .appBundleAgent(bundlePath) = job.domain { bundlePath } else { nil }
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func parentFolder(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}
