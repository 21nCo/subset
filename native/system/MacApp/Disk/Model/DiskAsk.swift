import Foundation
import SystemCore
import SystemProcesses

/// What Ask's disk tools (SET-51) read: the volume header and the scan shown, with its suggestions, redacted as Explain
/// redacts (SET-49). Nothing here scans, changes the window, or starts a cleanup.
extension DiskWindowModel {
    /// The volume's space and the scan's folder, state, and total, with when each was read.
    public func askDiskSummary(redactor: ExplainRedactor, now: Date = .now) -> AskOutput {
        var fields = askObserved(now: now)
        if let header = volumeHeader {
            // Never the header's title, which is the mount point when the volume has no name: that is a path.
            if let name = header.name { fields["volume"] = .name(name) }
            if let mountPoint = header.mountPoint { fields["mountedAt"] = .path(redactor.path(mountPoint)) }
            fields["capacity"] = .words(header.capacity)
            fields["availableForImportantUse"] = .words(header.availableForImportantUse)
            fields["purgeable"] = .words(header.purgeable)
            // The count only: why snapshots could not be listed is tmutil's message, which is never sent.
            fields["localSnapshots"] = .words(header.snapshotCount.map { "\($0), sizes unavailable" } ?? "Unavailable")
        }
        if let tree = result?.tree {
            fields["scannedFolder"] = .path(redactor.path(tree.rootPath))
            fields["total"] = .words(DiskFigures(tree.root.sizes, flags: tree.root.flags, format: format).accessibilityValue)
            fields["unreadableItems"] = .count(result?.unreadablePaths.count ?? 0)
        }
        if let analysis { fields["suggestions"] = .count(analysis.matches.count) }
        return AskOutput(fields)
    }

    /// The `limit` largest files and packages in the scan shown, from the list the scan made, so nothing walks the
    /// tree on the main actor.
    public func askLargestItems(limit: Int, redactor: ExplainRedactor, now: Date = .now) -> AskOutput {
        guard let result else { return AskOutput(["status": .words("No disk scan has finished yet.")]) }
        let tree = result.tree
        let entries = result.largestFiles.prefix(max(0, limit)).map { index in
            let item = tree[index]
            let path = tree.path(of: index)
            var fields: [String: AskValue] = [
                "name": .name(redactor.name(Self.name(item.name), ofPath: path)),
                "path": .path(redactor.path(path)),
                "type": .words(item.kind.title),
                "size": .words(DiskFigures(item.sizes, flags: item.flags, format: format).accessibilityValue)
            ]
            if let touched = item.touched {
                fields["lastChanged"] = .words(ExplainFacts.duration(from: touched, to: now) + " ago")
            }
            return AskEntry(.diskItem(path: path), fields)
        }
        return AskOutput(askObserved(now: now).merging(["scannedFolder": .path(redactor.path(tree.rootPath))]) { $1 },
                         entries: entries)
    }

    static let askSuggestionLimit = 20

    /// The suggestions of the scan shown, in the Suggestions tab's order of rules.
    public func askReclaimSuggestions(redactor: ExplainRedactor, now: Date = .now) -> AskOutput {
        guard let analysis, result != nil else {
            return AskOutput(["status": .words("No suggestions: they are worked out once a disk scan finishes without "
                + "being cancelled.")])
        }
        let entries = analysis.matches.indices.prefix(Self.askSuggestionLimit).map { position in
            let match = analysis.matches[position]
            let rule = match.rule
            var fields: [String: AskValue] = [
                "rule": .words(rule.name),
                "risk": .words(match.risk.title),
                "whatItIs": .words(rule.explanation),
                "comesBack": .words(rule.rebuild),
                "cleanup": .words(rule.yield.note),
                "items": .count(match.items.count),
                "itemNames": .names(ExplainFacts.countedNames(match.items, limit: 5, name: { redactor.name(ofPath: $0.path) },
                                                              precedes: Self.precedes))
            ]
            fields["size"] = .words(Self.sizes(of: match.bytes, format: format) ?? "Not measured")
            if case .unavailable = match.bytes {
                let reason = rule.id == .dockerImages ? ExplainNotMeasured(docker: analysis.dockerUnavailable) : .notRead
                fields["notMeasuredBecause"] = .words(reason.title)
            }
            if let app = match.app { fields["app"] = .name(Self.appName(app, redactor: redactor)) }
            if cleanedMatches.contains(position) { fields["cleanedUpThisSession"] = .flag(true) }
            return AskEntry(explainKey(for: .match(position)).map { .suggestion($0.id) }, fields)
        }
        var fields = askObserved(now: now)
        fields["scannedFolder"] = .path(redactor.path(result?.tree.rootPath ?? home))
        if analysis.matches.count > entries.count { fields["notListed"] = .count(analysis.matches.count - entries.count) }
        return AskOutput(fields, entries: entries)
    }

    /// The scan's state, and when the scan shown stopped reading and the volume's figures were read, with how long
    /// ago: each is read once per scan, so every disk tool says how old its figures are.
    private func askObserved(now: Date) -> [String: AskValue] {
        var fields: [String: AskValue] = ["scan": .words(askScanState)]
        if let scanEndedAt { fields["scanEnded"] = .words(Self.askTime(scanEndedAt, now: now, format: format)) }
        if let volumeReadAt { fields["volumeRead"] = .words(Self.askTime(volumeReadAt, now: now, format: format)) }
        return fields
    }

    private static func askTime(_ date: Date, now: Date, format: UsageFormat) -> String {
        "At \(format.time(date)), \(ExplainFacts.duration(from: date, to: now)) ago"
    }

    /// The scan's state in System's words, without a failure's message.
    private var askScanState: String {
        switch phase {
        case .idle: "No scan yet"
        case .scanning: "Scanning"
        case .analyzing: "Working out origins and suggestions"
        case .completed: "Finished"
        case .cancelled: "Cancelled; folders not read in full count only what was read"
        case .failed: "Failed"
        }
    }
}

/// The window Ask reads and selects in: the Processes section's sample and the Disk section's scan. A citation shows
/// its section, then selects what it cites there.
@MainActor
public final class AskWindowSource: AskSource {
    private let processes: ProcessesWindowModel
    private let disk: DiskWindowModel
    private let showProcesses: @MainActor () -> Void
    private let showDisk: @MainActor () -> Void

    public init(processes: ProcessesWindowModel, disk: DiskWindowModel, showProcesses: @escaping @MainActor () -> Void,
                showDisk: @escaping @MainActor () -> Void) {
        self.processes = processes
        self.disk = disk
        self.showProcesses = showProcesses
        self.showDisk = showDisk
    }

    public func topGroups(by metric: AskMetric, layer: AttributionLayer, limit: Int, redactor: ExplainRedactor) -> AskOutput {
        processes.askTopGroups(by: metric, layer: layer, limit: limit, redactor: redactor)
    }

    public func groupDetail(_ group: OriginGroupID, redactor: ExplainRedactor) -> AskOutput? {
        processes.askGroupDetail(group, redactor: redactor)
    }

    public func memoryState() -> AskOutput { processes.askMemoryState() }

    public func diskSummary(redactor: ExplainRedactor) -> AskOutput { disk.askDiskSummary(redactor: redactor) }

    public func largestItems(limit: Int, redactor: ExplainRedactor) -> AskOutput {
        disk.askLargestItems(limit: limit, redactor: redactor)
    }

    public func reclaimSuggestions(redactor: ExplainRedactor) -> AskOutput { disk.askReclaimSuggestions(redactor: redactor) }

    public func select(_ target: AskTarget) -> Bool {
        switch target {
        case let .group(id):
            guard processes.contains(id) else { return false }
            showProcesses()
            processes.reveal(id)
            return true
        case let .diskItem(path):
            guard disk.reveal(path: path) else { return false }
            showDisk()
            return true
        case let .suggestion(key):
            guard disk.revealSuggestion(key) else { return false }
            showDisk()
            return true
        }
    }
}
