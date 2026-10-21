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

    /// Something was moved to the Trash, or the command ran; a cleanup that did nothing can be tried again.
    public var didAct: Bool {
        switch outcome {
        case let .trash(items): items.contains { if case .moved = $0.status { true } else { false } }
        case let .command(_, result): result.ran
        case .notConfirmed: false
        }
    }
}

/// Carries out confirmed previews: moves items to the Trash after checking each again, or runs an allowlisted
/// command. It never deletes anything itself and never empties the Trash. Each confirmation is accepted once.
public actor CleanupExecutor {
    let protection: CleanupProtection
    let commands: CleanupCommands
    let trash: @Sendable (URL) throws -> URL?
    let freeSpace: @Sendable () -> Int64?
    /// Reads what is at a path now (`DiskItemIdentity.current`).
    let identify: @Sendable (String) -> DiskItemCurrent
    private var used: Set<UUID> = []

    /// This Mac's: the Finder's Trash (`FileManager.trashItem`) and the free space of `home`'s volume.
    public init(home: String, commands: CleanupCommands? = nil) {
        self.init(protection: CleanupProtection(home: home), commands: commands ?? CleanupCommands(home: home),
                  trash: Self.moveToTrash, freeSpace: { Self.freeSpace(of: home) })
    }

    init(protection: CleanupProtection, commands: CleanupCommands, trash: @escaping @Sendable (URL) throws -> URL?,
         freeSpace: @escaping @Sendable () -> Int64?,
         identify: @escaping @Sendable (String) -> DiskItemCurrent = { DiskItemIdentity.current(atPath: $0) }) {
        self.protection = protection
        self.commands = commands
        self.trash = trash
        self.freeSpace = freeSpace
        self.identify = identify
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

    /// Checks the item again and moves it to the Trash. The check and the move are separate calls, so another item can
    /// take its place in between, or the folder holding it can be moved elsewhere, into a protected folder say, with a
    /// link left at its path. So afterwards what reached the Trash is compared with the scanned item, and the folder at
    /// the item's path with the one checked: only the scanned item, taken from that folder, counts as moved; anything
    /// else is put back where it was, never over what is there now; and what cannot be checked or put back is reported
    /// failed, with where it is in the Trash. A change undone before the second check is not seen, but then the item
    /// moved is still the scanned one, from a folder that was at its path at both checks.
    private func move(_ item: CleanupItem) -> CleanupResult.ItemOutcome {
        if Task.isCancelled { return .init(path: item.path, status: .skipped(.stopped)) }
        let folder: FolderIdentity
        switch item.check(protection, identify: identify) {
        case let .failure(reason): return .init(path: item.path, status: .skipped(reason))
        case let .success(checked): folder = checked
        }
        guard let identity = item.identity else { return .init(path: item.path, status: .skipped(.notIdentified)) }
        let moved: URL?
        do {
            moved = try trash(URL(fileURLWithPath: item.path))
        } catch {
            return .init(path: item.path, status: .failed(error.localizedDescription))
        }
        guard let moved else {
            return .init(path: item.path, status: .failed(
                "It was moved to the Trash, which did not say where, so System could not check that it was the item the scan read."))
        }
        let trashPath = moved.path
        switch identify(trashPath) {
        case let .item(now, _) where now.isSameFile(as: identity):
            if FolderIdentity.read((item.path as NSString).deletingLastPathComponent) == .success(folder) {
                return .init(path: item.path, status: .moved(trashPath: trashPath))
            }
            return putBack(item, from: trashPath, reason: .folderChangedWhileMoving,
                           failure: "The folder holding it moved or became a link during the move")
        case .item, .symlink:
            return putBack(item, from: trashPath, reason: .replacedWhileMoving,
                           failure: "Another item took its place just before the move")
        case .missing:
            return .init(path: item.path, status: .failed(
                "It was moved to the Trash, but nothing is at \(trashPath), so System could not check what was moved."))
        case let .unreadable(code):
            return .init(path: item.path, status: .failed(
                "What was moved to the Trash, at \(trashPath), could not be checked (\(String(cString: strerror(code)))); "
                    + "it is still there."))
        }
    }

    /// Moves what reached the Trash back along the item's path, so a folder above it that is now a link leads it back
    /// where it was taken from, and never over what is there now.
    private func putBack(_ item: CleanupItem, from trashPath: String, reason: CleanupSkipReason, failure: String)
        -> CleanupResult.ItemOutcome {
        guard renamex_np(trashPath, item.path, UInt32(RENAME_EXCL)) == 0 else {
            let error = errno
            return .init(path: item.path, status: .failed(
                "\(failure); what was moved is in the Trash, at \(trashPath), and could not be put back: "
                    + "\(String(cString: strerror(error)))."))
        }
        return .init(path: item.path, status: .skipped(reason))
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
