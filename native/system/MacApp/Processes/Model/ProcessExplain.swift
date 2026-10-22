import Foundation
import SystemCore

/// What Explain sends for a group or process: the facts the window already shows, with paths redacted.
extension ProcessesWindowModel {
    /// The same for a row in every sample and layer it appears in, so its explanation is kept for the session.
    public nonisolated static func explainKey(for row: RowID) -> ExplainKey {
        switch row {
        case let .group(id): ExplainKey("process-group:\(id)")
        case let .process(identity): ExplainKey("process:\(identity.pid):\(identity.startTime)")
        }
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
        var result = ExplainFacts(kind: .processGroup, name: Self.explainName(group.id, group.displayName, redactor: redactor,
                                                                             isSubject: true))
        let layer = group.id.layer
        result.type = "\(group.id.subgroup == nil ? "Group" : "Subgroup") in the \(layer.title) layer"
        result.path = Self.path(of: group.id)
        let members = UsageOrder.processes(group.members.compactMap { facts[$0] }, by: .memory)
        result.members = ExplainFacts.countedNames(members.map(\.displayName))
        let totals = group.totals
        result.sizes = "\(totals.processCount) processes; memory \(format.spokenTotal(totals.memory, format.bytes)); "
            + "CPU \(format.spokenTotal(totals.cpuPercent, format.percent)) of one core"
        let signatures = members.compactMap { $0.origin?.codeSignature.value }
        if let first = signatures.first, signatures.allSatisfy({ $0.teamID == first.teamID }) {
            result.teamID = first.teamID
            result.vendor = first.isPlatformBinary ? "Apple" : first.teamName
        }
        if case let .launchdJob(label) = group.id.origin {
            result.launchdLabel = label
        } else if group.id.origin == .macOS {
            result.launchdLabel = group.id.subgroup
        }
        // The largest member's placement stands for the group's: every member was placed by the same layer's rules.
        if let largest = members.first, let placement = placement(of: largest, redactor: redactor) {
            result.matchedRule = placement.rule
            result.evidence = placement.evidence.map { "\(largest.displayName): \($0)" }
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
        if let placement = placement(of: process, redactor: redactor) {
            result.type = "Process in \(placement.group) (\(layer.title) layer)"
            result.matchedRule = placement.rule
            result.evidence = placement.evidence + placement.conflicts
        }
        return result
    }

    private func placement(of process: ProcessFacts, redactor: ExplainRedactor) -> PlacementDetail? {
        guard let placed = sample?.attribution.attribution(of: process.identity) else { return nil }
        let explanation = OriginExplanation(process: process, format: format, path: { redactor.path($0) }) { [names] in
            names[$0]
        }
        return PlacementDetail(layer: layer, attribution: placed, explanation: explanation) { [groups] id in
            Self.explainName(id, groups[id]?.displayName ?? OriginGroup.displayName(id.name(members: [process])),
                             redactor: redactor, isSubject: false)
        }
    }

    /// A group's name as sent. A group standing for a path in the home folder (a project, or an Unattributed
    /// executable, which is named by its path) is named as the redactor shows that path; `isSubject` keeps the name of
    /// the group being explained.
    private static func explainName(_ id: OriginGroupID, _ name: String, redactor: ExplainRedactor, isSubject: Bool) -> String {
        guard let path = path(of: id), redactor.isInHome(path) else { return name }
        if name == path { return redactor.path(path, isSubject: isSubject) }
        return isSubject ? name : redactor.name(ofPath: path)
    }
}
