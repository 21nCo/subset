import Foundation
import SystemCore

/// What Explain sends for a group or process: the facts the window already shows, as structured values.
extension ProcessesWindowModel {
    /// The same for a row in every sample it appears in, so its explanation is kept for the session. A process is
    /// placed, and so explained, by each layer's rules, so it has a key per layer, as a group (whose ID holds its layer)
    /// does; and a process that runs another executable (`exec` keeps its PID and start time) is another item.
    public func explainKey(for row: RowID) -> ExplainKey {
        switch row {
        case let .group(id):
            return ExplainKey("process-group:\(id)")
        case let .process(identity):
            let executable = facts[identity].map { $0.executablePath ?? "name:" + $0.name } ?? ""
            return ExplainKey("process:\(layer.rawValue):\(identity.pid):\(identity.startTime):\(executable)")
        }
    }

    /// The request for a row Explain was chosen for under `key`, or `nil` when the row now has another key (the layer
    /// changed, or the process runs another executable) or is gone.
    public func explainRequest(for row: RowID, key: ExplainKey, redactor: ExplainRedactor) -> ExplainRequest? {
        explainKey(for: row) == key ? explainRequest(for: row, redactor: redactor) : nil
    }

    /// The request for a row of the current sample, or `nil` when it is gone.
    public func explainRequest(for row: RowID, redactor: ExplainRedactor, now: Date = .now) -> ExplainRequest? {
        switch row {
        case let .group(id): groups[id].map { ExplainRequest(explainFacts($0, redactor: redactor), redactor: redactor) }
        case let .process(identity):
            facts[identity].map { ExplainRequest(explainFacts($0, redactor: redactor, now: now), redactor: redactor) }
        }
    }

    private func explainFacts(_ group: OriginGroup, redactor: ExplainRedactor) -> ExplainFacts {
        var result = ExplainFacts(kind: .processGroup, name: Self.explainName(group.id, group.displayName, redactor: redactor))
        let layer = group.id.layer
        result.type = "\(group.id.subgroup == nil ? "Group" : "Subgroup") in the \(layer.title) layer"
        result.path = Self.path(of: group.id)
        let members = UsageOrder.processes(group.members.compactMap { facts[$0] }, by: .memory)
        result.members = ExplainFacts.countedNames(members.map(\.displayName))
        let totals = group.totals
        result.sizes = "\(totals.processCount) processes; memory \(format.spokenTotal(totals.memory, format.bytes)); "
            + "CPU \(format.spokenTotal(totals.cpuPercent, format.percent)) of one core"
        if let identity = Self.sharedIdentity(group.members.map { facts[$0]?.origin?.codeSignature.value }) {
            result.teamID = identity.teamID
            result.vendor = identity.vendor
        }
        if case let .launchdJob(label) = group.id.origin {
            result.launchdLabel = label
        } else if group.id.origin == .macOS {
            result.launchdLabel = group.id.subgroup
        }
        // The largest member's placement stands for the group's: every member was placed by the same layer's rules.
        if let largest = members.first, let placement = placement(of: largest, in: layer, redactor: redactor) {
            result.matchedRule = placement.rule
            result.evidence = placement.evidence
        }
        result.isUnattributedGroup = group.id.subgroup == nil && {
            if case .unattributed = group.id.origin { return true }
            return false
        }()
        return result
    }

    private func explainFacts(_ process: ProcessFacts, redactor: ExplainRedactor, now: Date) -> ExplainFacts {
        var result = ExplainFacts(kind: .process, name: process.displayName)
        result.path = process.executablePath
        let signature = process.origin?.codeSignature.value
        result.signingID = signature?.signingID
        result.teamID = signature?.teamID
        result.vendor = signature?.isPlatformBinary == true ? "Apple" : signature?.teamName
        result.launchdLabel = process.launchdLabel
        result.sizes = process.restricted
            ? "Usage restricted by macOS"
            : "memory \(format.bytes(process.physFootprint)); CPU \(format.percent(process.cpuPercent)) of one core"
        let started = Date(timeIntervalSince1970: Double(process.identity.startTime) / 1_000_000)
        result.age = "Running for " + ExplainFacts.duration(from: started, to: now)
        result.type = "Process placed in the \(layer.title) layer"
        if let placement = placement(of: process, in: layer, redactor: redactor) {
            result.group = placement.group
            result.matchedRule = placement.rule
            result.evidence = placement.evidence
        }
        return result
    }

    /// Where `layer` placed a process: its group and subgroup, named as Explain names groups, the rule, and the evidence.
    private func placement(of process: ProcessFacts, in layer: AttributionLayer,
                           redactor: ExplainRedactor) -> (group: String, rule: String, evidence: [ExplainFacts.Evidence])? {
        guard let placed = sample?.attribution.attribution(of: process.identity) else { return nil }
        let names = names
        func groupName(_ id: OriginGroupID) -> String {
            Self.explainName(id, groups[id]?.displayName ?? OriginGroup.displayName(id.name(members: [process])),
                             redactor: redactor)
        }
        func make<Rule>(_ placement: Placement<Rule>, _ rule: String) -> (String, String, [ExplainFacts.Evidence]) {
            (groupName(placement.group) + (placement.subgroup.map { " › " + groupName($0) } ?? ""), rule,
             placement.evidence.map { ExplainFacts.Evidence($0, of: process) { names[$0] } })
        }
        return switch layer {
        case .app: make(placed.app, OriginExplanation.rule(placed.app.rule))
        case .vendor: make(placed.vendor, OriginExplanation.rule(placed.vendor.rule))
        case .launchSource: make(placed.launchSource, OriginExplanation.rule(placed.launchSource.rule))
        case .project: make(placed.project, OriginExplanation.rule(placed.project.rule))
        }
    }

    /// The Team ID and vendor every member's signature names, or `nil` unless every signature was read and names the
    /// same identity: one Team ID, or Apple for platform code. Unsigned and ad-hoc code have no identity, so a group
    /// with any of it, or with a member whose signature is unknown, is sent without one.
    nonisolated static func sharedIdentity(_ signatures: [CodeSignature?]) -> (teamID: String?, vendor: String?)? {
        guard let first = signatures.first ?? nil else { return nil }
        if let teamID = first.teamID {
            guard signatures.allSatisfy({ $0?.teamID == teamID }) else { return nil }
            let names = Set(signatures.map { $0?.teamName })
            return (teamID, names.count == 1 ? first.teamName : nil)
        }
        guard signatures.allSatisfy({ $0.map { $0.teamID == nil && $0.isPlatformBinary } ?? false }) else { return nil }
        return (nil, "Apple")
    }

    /// A group's name as sent. A group standing for a path in the home folder (an app, a login item, a project, or an
    /// Unattributed executable, which is named by its path) is named as the redactor names that path's last folder or
    /// file, the explained group's own name included; its path is sent as a path of its own.
    private static func explainName(_ id: OriginGroupID, _ name: String, redactor: ExplainRedactor) -> String {
        guard let path = path(of: id), redactor.isInHome(path) else { return name }
        return name == path ? redactor.name(ofPath: path) : redactor.name(name, ofPath: path)
    }
}
