import Foundation
import Observation
import SystemCore
import SystemProcesses

/// The confirmation sheet's state for one suggestion: the items chosen, the preview of exactly those, and, once
/// confirmed, the run and its result. It alone issues the confirmation a cleanup needs (`confirm()`), for the preview
/// shown at that moment.
@MainActor
@Observable
public final class CleanupSheet: Identifiable {
    public enum Phase: Equatable, Sendable {
        case reviewing
        case running
        case finished(CleanupResult)
    }

    public let id = UUID()
    public let match: ReclaimMatch
    /// The match's position in the analysis.
    public let matchIndex: Int
    public private(set) var phase: Phase = .reviewing
    /// The chosen items' paths, for a Trash cleanup.
    public private(set) var chosen: Set<String>
    /// The preview of what is chosen now, or why there is none.
    public private(set) var preview: Result<CleanupPreview, CleanupPlanError>

    @ObservationIgnored private let commands: CleanupCommands
    @ObservationIgnored private let protection: CleanupProtection

    /// A `safe` rule starts with every item chosen, so it is confirmed as one action; a `review` rule starts with none.
    init(match: ReclaimMatch, index: Int, commands: CleanupCommands, protection: CleanupProtection) {
        self.match = match
        matchIndex = index
        self.commands = commands
        self.protection = protection
        chosen = match.risk == .safe ? Set(match.items.map(\.path)) : []
        preview = .failure(.nothingSelected)
        refresh()
    }

    /// A command runs as a whole; Trash cleanups list their items to choose from.
    public var isCommand: Bool {
        if case .command = match.cleanup { return true }
        return false
    }

    /// Whether every item can be chosen at once, which only a `safe` rule allows.
    public var allowsChoosingAll: Bool { match.risk == .safe && !isCommand }

    public func isChosen(_ path: String) -> Bool { chosen.contains(path) }

    public func setChosen(_ path: String, _ isChosen: Bool) {
        guard phase == .reviewing, match.items.contains(where: { $0.path == path }) else { return }
        if isChosen { chosen.insert(path) } else { chosen.remove(path) }
        refresh()
    }

    public func chooseAll(_ all: Bool) {
        guard phase == .reviewing, allowsChoosingAll else { return }
        chosen = all ? Set(match.items.map(\.path)) : []
        refresh()
    }

    /// Every change of the choice makes a new preview, so a confirmation of an earlier one no longer matches.
    private func refresh() {
        let selection: CleanupSelection
        if isCommand || (match.risk == .safe && chosen.count == match.items.count) {
            selection = .all
        } else {
            selection = .items(chosen)
        }
        preview = Result { () throws(CleanupPlanError) in
            try CleanupPreview.make(match, selection: selection, commands: commands, protection: protection)
        }
    }

    /// The user's confirmation of the preview shown now, or `nil` when there is nothing to confirm or it was confirmed
    /// already. One confirmation covers one action.
    public func confirm() -> CleanupConfirmation? {
        guard phase == .reviewing, case let .success(preview) = preview, preview.canConfirm else { return nil }
        phase = .running
        return CleanupConfirmation(preview)
    }

    func finish(_ result: CleanupResult) {
        phase = .finished(result)
    }

    public var isRunning: Bool { phase == .running }
}

extension DiskWindowModel {
    /// The match a Suggestions row stands for, the row of one of its items included.
    func matchIndex(_ id: DiskRowID) -> Int? {
        switch id {
        case let .match(index), let .matchItem(index, _): index
        default: nil
        }
    }

    /// Whether the row's suggestion offers a cleanup now: a rule with one, an item to move or a command to run, not
    /// cleaned up already since this scan, and no other cleanup or scan running.
    public func canCleanUp(_ id: DiskRowID) -> Bool {
        guard tab == .suggestions, phase == .completed, !isCleaning, let index = matchIndex(id),
              let match = analysis?.matches[safe: index], !cleanedMatches.contains(index) else { return false }
        switch match.cleanup {
        case .none: return false
        case .command: return true
        case .trash, .trashEachItem, .trashPerApp: return !match.items.isEmpty
        }
    }

    /// Opens the confirmation sheet for the row's suggestion.
    public func beginCleanup(_ id: DiskRowID) {
        guard cleanupSheet == nil, canCleanUp(id), let index = matchIndex(id), let match = analysis?.matches[index]
        else { return }
        cleanupSheet = CleanupSheet(match: match, index: index, commands: cleanup.commands, protection: cleanup.protection)
    }

    /// Closes the sheet; not while its cleanup runs.
    public func dismissCleanup() {
        guard cleanupSheet?.isRunning != true else { return }
        cleanupSheet = nil
    }

    /// Carries out the sheet's preview with the confirmation the sheet issued for it. The result is shown in the sheet
    /// and kept in `cleanupResults` for the session.
    public func perform(_ confirmation: CleanupConfirmation) {
        guard let sheet = cleanupSheet, sheet.isRunning, case let .success(preview) = sheet.preview else { return }
        let executor = cleanup.executor
        cleanupTask = Task { [weak self] in
            let result = await executor.perform(preview, confirmation: confirmation)
            guard let self else { return }
            sheet.finish(result)
            if result.outcome != .notConfirmed { cleanedMatches.insert(sheet.matchIndex) }
            cleanupResults.append(result)
            cleanupTask = nil
            isStoppingCleanup = false
            rebuild()
        }
    }

    /// Stops a running cleanup: items not moved yet are skipped, and a command is stopped. The cleanup still runs, and
    /// `isStoppingCleanup` is set, until the command and the programs it started have exited.
    public func stopCleanup() {
        guard let cleanupTask, !isStoppingCleanup else { return }
        isStoppingCleanup = true
        cleanupTask.cancel()
    }

    public var isCleaning: Bool { cleanupTask != nil }
}

/// What a cleanup needs from this Mac, injected so tests use fixtures and a stub executable.
public struct DiskCleanupService: Sendable {
    public let protection: CleanupProtection
    public let commands: CleanupCommands
    public let executor: CleanupExecutor

    public init(protection: CleanupProtection, commands: CleanupCommands, executor: CleanupExecutor) {
        self.protection = protection
        self.commands = commands
        self.executor = executor
    }

    public static func live(home: String) -> DiskCleanupService {
        let commands = CleanupCommands(home: home)
        return DiskCleanupService(protection: CleanupProtection(home: home), commands: commands,
                                  executor: CleanupExecutor(home: home, commands: commands))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: Text

extension CleanupSheet {
    /// The confirm button's title, saying what it does.
    public var confirmTitle: String {
        guard case let .success(preview) = preview else { return isCommand ? "Run" : "Move to Trash" }
        switch preview.action {
        case let .trash(items):
            let count = items.filter { preview.refusals[$0.path] == nil }.count
            return "Move \(count) Item\(count == 1 ? "" : "s") to the Trash"
        case let .command(tool, _):
            return "Run \(tool.rawValue) \(tool.arguments.joined(separator: " "))"
        }
    }
}

extension CleanupEstimate {
    /// "≥ 1.2 MB", "≤ 300 MB", or "Unknown".
    public func text(_ format: UsageFormat) -> String {
        guard let bytes else { return "Unknown" }
        return (isLowerBound ? "≥ " : isUpperBound ? "≤ " : "") + format.diskBytes(bytes)
    }
}

extension CleanupResult.ItemStatus {
    public var text: String {
        switch self {
        case .moved: "Moved to the Trash"
        case let .skipped(reason): "Skipped: " + reason.text
        case let .failed(message): "Failed: " + message
        }
    }
}

extension CleanupResult {
    /// One line saying what happened and how the free space changed beside the estimate.
    public func summary(_ format: UsageFormat) -> String {
        let what: String
        switch outcome {
        case .notConfirmed:
            return "Nothing was done: the confirmation was not for this cleanup, or was used already."
        case let .trash(items):
            func count(_ match: (ItemStatus) -> Bool) -> Int { items.filter { match($0.status) }.count }
            let moved = count { if case .moved = $0 { true } else { false } }
            let skipped = count { if case .skipped = $0 { true } else { false } }
            let failed = count { if case .failed = $0 { true } else { false } }
            what = "Moved \(format.count(moved)) to the Trash, skipped \(format.count(skipped)), failed \(format.count(failed))."
        case let .command(command, result):
            let name = command?.commandLine ?? title
            what = switch result {
            case .exited(0, _): "\(name) finished."
            case let .exited(status, _): "\(name) failed with exit status \(status)."
            case let .timedOut(seconds): "\(name) was stopped after \(seconds / 60) minutes without finishing."
            case let .launchFailed(message): "\(name) could not be started: \(message)"
            case .outputTooLarge: "\(name) printed more than System reads, so it was stopped."
            case .cancelled: "\(name) was stopped."
            case let .refused(reason): "Not run: \(reason)"
            }
        }
        let freed = freedBytes.map { bytes in
            bytes >= 0 ? "Free space grew by \(format.diskBytes(bytes))" : "Free space shrank by \(format.diskBytes(bytes.magnitude))"
        } ?? "The change in free space is unknown"
        return "\(what) \(freed) (estimate \(estimate.text(format)))."
    }

    /// The command's printed lines shown, at most `CleanupCommands.outputLineLimit`, with a note of those left out.
    public var outputLines: [String] {
        guard case let .command(_, .exited(_, output)) = outcome else { return [] }
        return (output.omitted > 0 ? ["… \(output.omitted) earlier lines not shown"] : []) + output.lines
    }
}
