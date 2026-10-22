import Foundation
import SystemCore
import SystemProcesses

/// What Explain sends for a scanned item, leftover, or suggestion: the facts the Disk section already shows, with paths
/// redacted. Groups and Show more rows are not explained.
extension DiskWindowModel {
    /// Whether Explain is offered for a row: a scanned item, an origin group's or suggestion's item, or a suggestion.
    public func canExplain(_ id: DiskRowID) -> Bool {
        guard result != nil else { return false }
        switch id {
        case .item, .originItem, .match, .matchItem: return true
        case .originGroup, .more: return false
        }
    }

    /// Kept across scans for the same path or suggestion, so its explanation is kept for the session; `nil` for a row
    /// Explain does not offer.
    public func explainKey(for id: DiskRowID) -> ExplainKey? {
        guard let tree = result?.tree else { return nil }
        switch id {
        case let .item(index), let .originItem(_, _, index), let .matchItem(_, index):
            return index < tree.count ? ExplainKey("disk:\(tree.path(of: index))") : nil
        case let .match(position):
            guard let match = analysis?.matches[safe: position] else { return nil }
            return ExplainKey("disk-suggestion:\(match.rule.id.rawValue):\(match.identifier ?? ""):"
                + (match.items.first?.path ?? ""))
        case .originGroup, .more:
            return nil
        }
    }

    /// The request for a row of the scan shown, or `nil` for a row Explain does not offer.
    public func explainRequest(for id: DiskRowID, redactor: ExplainRedactor, now: Date = .now) -> ExplainRequest? {
        guard let tree = result?.tree else { return nil }
        let facts: ExplainFacts
        switch id {
        case let .item(index), let .matchItem(_, index):
            guard index < tree.count else { return nil }
            facts = itemFacts(index, in: tree, leftover: false, now: now)
        case let .originItem(_, key, index):
            guard index < tree.count else { return nil }
            facts = itemFacts(index, in: tree, leftover: key == .leftovers, now: now)
        case let .match(position):
            guard let match = analysis?.matches[safe: position] else { return nil }
            facts = matchFacts(match, redactor: redactor)
        case .originGroup, .more:
            return nil
        }
        return ExplainRequest(facts, redactor: redactor)
    }

    private func itemFacts(_ index: Int, in tree: DiskTree, leftover: Bool, now: Date) -> ExplainFacts {
        let item = tree[index]
        let entry = analysis?.origins.entries.first { $0.index == index }
        let isLeftover = leftover || entry?.rule == .leftover
        var facts = ExplainFacts(kind: isLeftover ? .leftover : .folder, name: Self.name(item.name))
        facts.type = item.kind.title + (entry.map { " in ~/\($0.folder.homePath)" } ?? "")
        facts.path = tree.path(of: index)
        facts.sizes = DiskFigures(item.sizes, flags: item.flags, format: format).accessibilityValue
        facts.age = item.touched.map { "Last changed " + ExplainFacts.duration(from: $0, to: now) + " ago" }
        if let entry {
            facts.bundleID = entry.app?.bundleID ?? (entry.rule == .unattributed ? nil : entry.identifier)
            facts.teamID = entry.teamID ?? entry.app?.signature?.teamID
            facts.vendor = entry.app?.signature?.teamName
            facts.matchedRule = Self.ruleText(entry.rule) + (entry.app.map { ": \($0.name)" } ?? "")
        }
        for match in analysis?.matches ?? [] where match.items.contains(where: { $0.index == index }) {
            facts.evidence.append("Matches the reclaim rule \(match.rule.name) (\(match.risk.title)): \(match.rule.explanation)")
        }
        return facts
    }

    private func matchFacts(_ match: ReclaimMatch, redactor: ExplainRedactor) -> ExplainFacts {
        let rule = match.rule
        var facts = ExplainFacts(kind: .suggestion,
                                 name: [rule.name, match.app?.name ?? match.identifier].compactMap { $0 }.joined(separator: ": "))
        facts.type = "\(match.risk.title) suggestion"
        facts.bundleID = match.app?.bundleID ?? match.identifier
        facts.teamID = match.app?.signature?.teamID
        facts.vendor = match.app?.signature?.teamName
        facts.matchedRule = "\(rule.name): \(rule.explanation)"
        facts.sizes = switch match.bytes {
        case let .scanned(privateBytes, allocated, complete, _):
            "\(complete ? "" : "at least ")\(format.diskBytes(allocated)) used, \(format.diskBytes(privateBytes)) private"
        case let .dockerReclaimable(upTo, _): "up to \(format.diskBytes(upTo)) reclaimable, as Docker reports"
        case let .unavailable(reason): "Not measured: \(reason)"
        }
        facts.evidence = ["Location: \(rule.location)", rule.rebuild, rule.yield.note]
        // Items are named as their paths are sent, so a project's or download's name is a placeholder unless folder
        // names are sent.
        facts.members = ExplainFacts.countedNames(match.items.sorted { ($0.sizes?.allocated ?? 0) > ($1.sizes?.allocated ?? 0) }
            .map { redactor.name(ofPath: $0.path) })
        return facts
    }

    static func ruleText(_ rule: DiskOriginRule) -> String {
        switch rule {
        case .developerTool: "A developer tool's folder"
        case .appGroup: "An app group an installed app declares"
        case .bundleID: "Named for an installed app's bundle ID"
        case .teamID: "Named for a Team ID installed apps share"
        case .appleIdentifier: "An Apple identifier: macOS's own data"
        case .appName: "Named for an installed app"
        case .leftover: "Named for a bundle ID no installed app has"
        case .possibleLeftover: "Possibly a leftover; an app could not be read"
        case .unattributed: "Not attributed to any app"
        }
    }
}
