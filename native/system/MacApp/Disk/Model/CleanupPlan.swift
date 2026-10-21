import Foundation
import SystemCore

/// What a cleanup covers of a match.
public enum CleanupSelection: Hashable, Sendable {
    /// Every item of the match, or its command, as one action: only for a `safe` rule.
    case all
    /// These items, by path, each chosen on its own.
    case items(Set<String>)
}

/// Why a preview cannot be made.
public enum CleanupPlanError: Error, Equatable, Sendable {
    /// The rule offers no cleanup (`info`).
    case noCleanup
    /// A `review` rule's items are each chosen; it has no one-action cleanup.
    case reviewNeedsEachItem
    case nothingSelected
    /// A chosen path is not one of the match's items.
    case notInMatch(String)
    /// A tool command runs as a whole; it has no items to choose.
    case commandHasNoItems
    /// The rule's command is not on the allowlist.
    case commandNotAllowed([String])

    public var text: String {
        switch self {
        case .noCleanup: "System offers no cleanup for this."
        case .reviewNeedsEachItem: "Choose each item to remove: this suggestion has no one-step cleanup."
        case .nothingSelected: "Choose at least one item."
        case let .notInMatch(path): "\(path) is not one of this suggestion's items."
        case .commandHasNoItems: "This cleanup runs a command as a whole; it has no items to choose."
        case let .commandNotAllowed(vector): "\(vector.joined(separator: " ")) is not a command System runs."
        }
    }
}

/// The bytes a preview expects its action to free, from the scan or Docker's report.
public struct CleanupEstimate: Equatable, Sendable {
    /// `nil` when unknown.
    public let bytes: UInt64?
    /// It is at least this much.
    public let isLowerBound: Bool
    /// It is at most this much.
    public let isUpperBound: Bool
    /// When the space comes back, from the rule's yield.
    public let note: String

    /// The items' private sum: what the Trash holds once they are moved there, freed when it is emptied.
    init(items: [CleanupItem]) {
        let known = items.compactMap(\.privateBytes)
        bytes = known.isEmpty ? nil : known.reduce(0, +)
        isLowerBound = items.contains { $0.isLowerBound || $0.privateBytes == nil }
        isUpperBound = false
        note = "Moving them to the Trash frees nothing yet: the space comes back once the Trash is emptied, which System "
            + "never does."
    }

    /// A command's match: the measured private sum, or Docker's upper bound.
    init(command match: ReclaimMatch) {
        switch match.bytes {
        case let .scanned(privateBytes, _, complete, _):
            (bytes, isLowerBound, isUpperBound) = (privateBytes, !complete, false)
        case let .dockerReclaimable(upTo, _):
            (bytes, isLowerBound, isUpperBound) = (upTo, false, true)
        case .unavailable:
            (bytes, isLowerBound, isUpperBound) = (nil, false, false)
        }
        note = switch match.rule.yield {
        case .partOfMeasured: "The tool keeps what is still in use, so it frees part of this, at once."
        case .reportedUpperBound: "Docker removes only dangling images, so it may free less than this, at once."
        default: "The tool decides what it deletes, so this is an estimate of what it frees, at once."
        }
    }
}

/// Exactly what one cleanup would do, for the confirmation sheet: every path or the command, the expected bytes, the
/// risk, and the rebuild note. Each preview has its own identity; changing the selection makes a new one.
public struct CleanupPreview: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Move these items to the Trash.
        case trash([CleanupItem])
        /// Run this command, or say why it cannot run.
        case command(CleanupTool, Result<ResolvedCommand, CleanupCommandUnavailable>)
    }

    public let id: UUID
    public let rule: ReclaimRule
    /// The rule's name, with the app or identifier a match is for.
    public let title: String
    public let action: Action
    public let estimate: CleanupEstimate
    /// Why an item will be refused, by path, as the protected places stand now; each is checked again when it runs.
    public let refusals: [String: String]

    public var risk: ReclaimRisk { rule.risk }
    public var rebuild: String { rule.rebuild }

    /// There is something to do: an item to move that is not refused, or a command found.
    public var canConfirm: Bool {
        switch action {
        case let .trash(items): items.contains { refusals[$0.path] == nil }
        case let .command(_, resolution): (try? resolution.get()) != nil
        }
    }

    /// Makes the preview of `selection` of `match`. A `review` rule's items must be chosen one by one; a command runs
    /// only when the rule's vector is on the allowlist, and its program is looked for at its fixed paths now.
    public static func make(_ match: ReclaimMatch, selection: CleanupSelection, commands: CleanupCommands,
                            protection: CleanupProtection) throws(CleanupPlanError) -> CleanupPreview {
        let rule = match.rule
        let title = [rule.name, match.app?.name ?? match.identifier].compactMap { $0 }.joined(separator: ": ")
        if rule.risk == .info { throw .noCleanup }
        if rule.risk == .review, selection == .all { throw .reviewNeedsEachItem }
        switch rule.cleanup {
        case .none:
            throw .noCleanup
        case let .command(vector):
            guard selection == .all else { throw .commandHasNoItems }
            guard let tool = CleanupTool.allowed(vector) else { throw .commandNotAllowed(vector) }
            return CleanupPreview(id: UUID(), rule: rule, title: title, action: .command(tool, commands.resolve(tool)),
                                  estimate: CleanupEstimate(command: match), refusals: [:])
        case .trash, .trashEachItem, .trashPerApp:
            let items: [ReclaimItem]
            switch selection {
            case .all:
                items = match.items
            case let .items(paths):
                if let stray = paths.sorted().first(where: { path in !match.items.contains { $0.path == path } }) {
                    throw .notInMatch(stray)
                }
                items = match.items.filter { paths.contains($0.path) }
            }
            guard !items.isEmpty else { throw .nothingSelected }
            let chosen = items.map(CleanupItem.init)
            let refusals = Dictionary(chosen.compactMap { item in protection.refusal(item.path).map { (item.path, $0) } },
                                      uniquingKeysWith: { first, _ in first })
            return CleanupPreview(id: UUID(), rule: rule, title: title, action: .trash(chosen),
                                  estimate: CleanupEstimate(items: chosen), refusals: refusals)
        }
    }
}

/// The user's confirmation of one preview: issued only by the confirmation sheet (`CleanupSheet.confirm()`), for that
/// preview's exact items or command, and accepted once. Nothing outside this module can make one.
public struct CleanupConfirmation: Sendable {
    let previewID: UUID
    let action: CleanupPreview.Action

    init(_ preview: CleanupPreview) {
        previewID = preview.id
        action = preview.action
    }

    /// Whether it confirms exactly this preview.
    func covers(_ preview: CleanupPreview) -> Bool {
        previewID == preview.id && action == preview.action
    }
}
