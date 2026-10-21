import Darwin
import Foundation
import SystemCore

/// What one cleanup did, kept for the session only.
public struct CleanupResult: Identifiable, Equatable, Sendable {
    public enum ItemStatus: Equatable, Sendable {
        /// Moved to the Trash, at this path there when the Finder reported it.
        case moved(trashPath: String?)
        case skipped(CleanupSkipReason)
        case failed(String)
    }

    public struct ItemOutcome: Equatable, Sendable {
        public let path: String
        public let status: ItemStatus
    }

    public enum Outcome: Equatable, Sendable {
        case trash([ItemOutcome])
        case command(ResolvedCommand?, CommandCleanupOutcome)
        /// Nothing ran: the confirmation was not for this preview, or was used already.
        case notConfirmed
    }

    /// The preview's.
    public let id: UUID
    public let title: String
    public let estimate: CleanupEstimate
    public let outcome: Outcome
    public let finishedAt: Date
    /// The free space on the home folder's volume just before and just after, in bytes; `nil` when not read.
    public let freeBefore: Int64?
    public let freeAfter: Int64?

    /// How much the volume's free space grew, which other programs writing at the same time also change; negative when
    /// it shrank. `nil` when either figure is unknown.
    public var freedBytes: Int64? {
        guard let freeBefore, let freeAfter else { return nil }
        return freeAfter - freeBefore
    }
}

/// Carries out confirmed previews: moves items to the Trash after checking each again, or runs an allowlisted
/// command. It never deletes anything itself and never empties the Trash. Each confirmation is accepted once.
public actor CleanupExecutor {
    let protection: CleanupProtection
    let commands: CleanupCommands
    let trash: @Sendable (URL) throws -> URL?
    let freeSpace: @Sendable () -> Int64?
    private var used: Set<UUID> = []

    /// This Mac's: the Finder's Trash (`FileManager.trashItem`) and the free space of `home`'s volume.
    public init(home: String, commands: CleanupCommands? = nil) {
        self.init(protection: CleanupProtection(home: home), commands: commands ?? CleanupCommands(home: home),
                  trash: Self.moveToTrash, freeSpace: { Self.freeSpace(of: home) })
    }

    init(protection: CleanupProtection, commands: CleanupCommands, trash: @escaping @Sendable (URL) throws -> URL?,
         freeSpace: @escaping @Sendable () -> Int64?) {
        self.protection = protection
        self.commands = commands
        self.trash = trash
        self.freeSpace = freeSpace
    }

    /// Carries out `preview` when `confirmation` was issued for exactly it and not used before; otherwise does
    /// nothing and says so. Cancelling the calling task skips the items not yet moved, or stops the command.
    public func perform(_ preview: CleanupPreview, confirmation: CleanupConfirmation) async -> CleanupResult {
        guard confirmation.covers(preview), used.insert(confirmation.previewID).inserted else {
            return result(preview, .notConfirmed, before: nil, after: nil)
        }
        let before = freeSpace()
        let outcome: CleanupResult.Outcome
        switch preview.action {
        case let .trash(items):
            outcome = .trash(items.map(move))
        case let .command(_, .success(command)):
            outcome = .command(command, await commands.run(command))
        case let .command(_, .failure(reason)):
            outcome = .command(nil, .refused(reason.text))
        }
        return result(preview, outcome, before: before, after: freeSpace())
    }

    private func result(_ preview: CleanupPreview, _ outcome: CleanupResult.Outcome, before: Int64?, after: Int64?)
        -> CleanupResult {
        CleanupResult(id: preview.id, title: preview.title, estimate: preview.estimate, outcome: outcome,
                      finishedAt: Date(), freeBefore: before, freeAfter: after)
    }

    /// Checks the item again and moves it to the Trash. The check and the move are separate calls, so an item swapped
    /// in between is moved; the Trash keeps it, and the moved item is compared with the scanned one afterwards.
    private func move(_ item: CleanupItem) -> CleanupResult.ItemOutcome {
        if Task.isCancelled { return .init(path: item.path, status: .skipped(.stopped)) }
        if let reason = item.revalidate(protection) { return .init(path: item.path, status: .skipped(reason)) }
        let moved: URL?
        do {
            moved = try trash(URL(fileURLWithPath: item.path))
        } catch {
            return .init(path: item.path, status: .failed(error.localizedDescription))
        }
        if let moved, let identity = item.identity, case let .item(now, _) = DiskItemIdentity.current(atPath: moved.path),
           !now.isSameFile(as: identity) {
            return .init(path: item.path, status: .failed(
                "What was moved to the Trash, at \(moved.path), is not the item the scan read; it is still in the Trash."))
        }
        return .init(path: item.path, status: .moved(trashPath: moved?.path))
    }

    @Sendable static func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// The bytes free for an unprivileged user on the volume holding `path` (`statfs`), read fresh each time.
    static func freeSpace(of path: String) -> Int64? {
        var volume = statfs()
        guard statfs(path, &volume) == 0 else { return nil }
        return Int64(clamping: UInt64(volume.f_bavail) &* UInt64(volume.f_bsize))
    }
}
