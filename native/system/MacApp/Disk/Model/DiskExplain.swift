import Foundation
import SystemCore
import SystemProcesses

/// What Explain sends for a scanned item, leftover, or suggestion: the facts the Disk section already shows, with paths
/// redacted. Groups and Show more rows are not explained.
extension DiskWindowModel {
    /// Whether Explain is offered for a row: a scanned item, an origin group's or suggestion's item, or a suggestion,
    /// once the scan is no longer being read or analyzed.
    public func canExplain(_ id: DiskRowID) -> Bool {
        guard result != nil, !isScanning else { return false }
        switch id {
        case .item, .originItem, .match, .matchItem: return true
        case .originGroup, .more: return false
        }
    }

    /// Kept across scans for the same path, asked about as a folder or a leftover, or the same suggestion, so its
    /// explanation is kept for the session; `nil` for a row Explain does not offer. An item of a scan without origins
    /// and suggestions, which was cancelled before they were worked out, has fewer facts, so it has its own key.
    public func explainKey(for id: DiskRowID) -> ExplainKey? {
        guard let tree = result?.tree, canExplain(id) else { return nil }
        switch id {
        case let .item(index), let .originItem(_, _, index), let .matchItem(_, index):
            guard index < tree.count else { return nil }
            let analyzed = analysis == nil ? "unanalyzed-" : ""
            return ExplainKey("disk-\(analyzed)\(itemKind(id, index: index).rawValue):\(tree.path(of: index))")
        case let .match(position):
            guard let match = analysis?.matches[safe: position] else { return nil }
            return ExplainKey("disk-suggestion:\(match.rule.id.rawValue):\(match.identifier ?? ""):"
                + (match.items.first?.path ?? ""))
        case .originGroup, .more:
            return nil
        }
    }

    /// The request for a row Explain was chosen for under `key`, or `nil` when the row now has another key (a newer scan
    /// put another item at its place, or the scan is analyzed differently) or Explain no longer offers it.
    public func explainRequest(for id: DiskRowID, key: ExplainKey, redactor: ExplainRedactor) -> ExplainRequest? {
        explainKey(for: id) == key ? explainRequest(for: id, redactor: redactor) : nil
    }

    /// The request for a row of the scan shown, or `nil` for a row Explain does not offer.
    public func explainRequest(for id: DiskRowID, redactor: ExplainRedactor, now: Date = .now) -> ExplainRequest? {
        guard let tree = result?.tree, canExplain(id) else { return nil }
        let facts: ExplainFacts
        switch id {
        case let .item(index), let .originItem(_, _, index), let .matchItem(_, index):
            guard index < tree.count else { return nil }
            facts = itemFacts(index, in: tree, kind: itemKind(id, index: index), redactor: redactor, now: now)
        case let .match(position):
            guard let match = analysis?.matches[safe: position] else { return nil }
            facts = matchFacts(match, in: tree, redactor: redactor)
        case .originGroup, .more:
            return nil
        }
        return ExplainRequest(facts, redactor: redactor)
    }

    /// A scanned item is asked about as a leftover in the Leftovers origin group or when a rule found it is one, and
    /// otherwise as a folder or file.
    private func itemKind(_ id: DiskRowID, index: Int) -> ExplainItemKind {
        if case .originItem(_, .leftovers, _) = id { return .leftover }
        return analysis?.origins.entries.first { $0.index == index }?.rule == .leftover ? .leftover : .folder
    }

    private func itemFacts(_ index: Int, in tree: DiskTree, kind: ExplainItemKind, redactor: ExplainRedactor,
                           now: Date) -> ExplainFacts {
        let item = tree[index]
        let path = tree.path(of: index)
        let entry = analysis?.origins.entries.first { $0.index == index }
        // Named as its path is sent: a placeholder deeper than the first level under ~ unless folder names are sent.
        var facts = ExplainFacts(kind: kind, name: redactor.name(Self.name(item.name), ofPath: path))
        facts.type = item.kind.title + (entry.map { " in ~/\($0.folder.homePath)" } ?? "")
        facts.path = path
        facts.sizes = DiskFigures(item.sizes, flags: item.flags, format: format).accessibilityValue
        facts.age = item.touched.map { "Last changed " + ExplainFacts.duration(from: $0, to: now) + " ago" }
        if let entry {
            facts.bundleID = Self.identifier(of: entry, redactor: redactor)
            facts.teamID = entry.teamID ?? entry.app?.signature?.teamID
            facts.vendor = entry.app?.signature?.teamName
            facts.matchedRule = Self.ruleText(entry.rule) + (entry.app.map { ": " + Self.appName($0, redactor: redactor) } ?? "")
        }
        for match in analysis?.matches ?? [] where match.items.contains(where: { $0.index == index }) {
            facts.evidence.append("Matches the reclaim rule \(match.rule.name) (\(match.risk.title)): \(match.rule.explanation)")
        }
        return facts
    }

    private func matchFacts(_ match: ReclaimMatch, in tree: DiskTree, redactor: ExplainRedactor) -> ExplainFacts {
        let rule = match.rule
        // Leftovers are named for their entries' identifier, sent as each entry's is.
        let entry = match.identifier == nil ? nil
            : match.items.first.flatMap { item in analysis?.origins.entries.first { $0.index == item.index } }
        let identifier = match.identifier.flatMap { identifier in
            entry.map { Self.identifier(of: $0, redactor: redactor) }
                ?? (DiskOrigins.isBundleID(identifier) || redactor.sendFolderNames ? identifier : nil)
        }
        var facts = ExplainFacts(kind: .suggestion,
                                 name: [rule.name, match.app.map { Self.appName($0, redactor: redactor) } ?? identifier]
                                     .compactMap { $0 }.joined(separator: ": "))
        facts.type = "\(match.risk.title) suggestion"
        facts.bundleID = match.app?.bundleID ?? identifier
        facts.teamID = match.app?.signature?.teamID ?? entry?.teamID
        facts.vendor = match.app?.signature?.teamName
        facts.matchedRule = "\(rule.name): \(rule.explanation)"
        facts.sizes = switch match.bytes {
        case let .scanned(privateBytes, allocated, complete, _):
            "\(complete ? "" : "at least ")\(format.diskBytes(allocated)) used, \(format.diskBytes(privateBytes)) private"
        case let .dockerReclaimable(upTo, _): "up to \(format.diskBytes(upTo)) reclaimable, as Docker reports"
        case let .unavailable(reason): "Not measured: " + redactingPaths(reason, in: tree, redactor: redactor)
        }
        facts.ruleEvidence = ["Location: \(rule.location)", rule.rebuild, rule.yield.note]
        // Items are named as their paths are sent, so a project's or download's name is a placeholder unless folder
        // names are sent.
        facts.members = ExplainFacts.countedNames(match.items.sorted { ($0.sizes?.allocated ?? 0) > ($1.sizes?.allocated ?? 0) }
            .map { redactor.name(ofPath: $0.path) })
        return facts
    }

    /// Free text from the scan, such as why a suggestion was not measured, with each path it names as the redactor
    /// sends it: a scanned path, or one outside the scanned folder that a reason names (`DiskAnalysis.knownPaths`),
    /// such as an app's or the Docker socket's. Known paths go first: a scan of the home folder would otherwise show
    /// only the part of such a path the scan read.
    func redactingPaths(_ text: String, in tree: DiskTree, redactor: ExplainRedactor) -> String {
        Self.redactingScannedPaths(redactor.paths(in: text, known: analysis?.knownPaths ?? []), in: tree, redactor: redactor)
    }

    /// `text` with each scanned path in it as the redactor sends it. A reason names a path whole and a folder name may
    /// hold a space, so the path's end is found by following the tree's names, the longest that matches at each level.
    static func redactingScannedPaths(_ text: String, in tree: DiskTree, redactor: ExplainRedactor) -> String {
        let root = tree.rootPath == "/" ? "" : tree.rootPath
        var result = ""
        var rest = text[...]
        while let found = rest.range(of: root.isEmpty ? "/" : root) {
            result += rest[..<found.lowerBound]
            var current = 0
            var end = root.isEmpty ? found.lowerBound : found.upperBound
            while rest[end...].hasPrefix("/") {
                let after = rest.index(after: end)
                let next = tree[current].children
                    .filter { !tree[$0].name.isEmpty && rest[after...].hasPrefix(tree[$0].name) }
                    .max { tree[$0].name.count < tree[$1].name.count }
                guard let next else { break }
                current = next
                end = rest.index(after, offsetBy: tree[next].name.count)
            }
            if current == 0, root.isEmpty {
                result += rest[found]
                rest = rest[found.upperBound...]
            } else {
                result += redactor.path(String(rest[found.lowerBound..<end]))
                rest = rest[end...]
            }
        }
        return result + rest
    }

    /// An installed app's name as sent, the same as Processes names its group: its bundle's name, or the bundle's
    /// placeholder for an app deeper than the first level under ~ (`~/Applications/Acme Notes.app`) unless folder names
    /// are sent.
    static func appName(_ app: InstalledApp, redactor: ExplainRedactor) -> String {
        redactor.name(app.name, ofPath: app.path)
    }

    /// The identifier a Library entry is sent as, only when it is known identity: its app's bundle ID, an app group an
    /// installed app declares, an Apple identifier, a developer tool's folder, or a bundle ID no installed app has. A name
    /// after a Team ID no installed app has, or several apps share, is the folder's own and is sent only with folder
    /// names, as is an unrecognized bundle ID's; an unattributed entry's is never sent (its name field is).
    static func identifier(of entry: DiskOriginEntry, redactor: ExplainRedactor) -> String? {
        if let app = entry.app { return app.bundleID }
        switch entry.rule {
        case .appGroup, .appleIdentifier, .developerTool:
            return entry.identifier
        case .bundleID, .teamID, .appName, .leftover, .possibleLeftover:
            return DiskOrigins.isBundleID(entry.identifier) || redactor.sendFolderNames ? entry.identifier : nil
        case .unattributed:
            return nil
        }
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
