import CryptoKit
import Darwin
import Foundation

/// Where an install looks and writes.
public struct InstallSetup: Sendable {
    /// /Applications, then ~/Applications (temporary folders in tests).
    public var folders: [ApplicationsFolder]
    /// ~/Library/Application Support/Subset/receipts.
    public var receipts: URL
    /// ~/Library/Application Support/Subset/locks, shared with the `subset` command.
    public var locks: URL
    /// Where each install makes its private folder.
    public var temporary: URL

    public init(folders: [ApplicationsFolder], receipts: URL, locks: URL, temporary: URL) {
        self.folders = folders
        self.receipts = receipts
        self.locks = locks
        self.temporary = temporary
    }

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstallSetup {
        let finder = InstalledAppFinder.standard(home: home)
        return InstallSetup(
            folders: finder.folders, receipts: finder.receipts,
            locks: home.appendingPathComponent("Library/Application Support/Subset/locks", isDirectory: true),
            temporary: FileManager.default.temporaryDirectory
        )
    }
}

/// What a finished operation did: the installed app (nil for a move to the Trash) and notes worth showing.
public struct InstallOutcome: Equatable, Sendable {
    public var path: String?
    public var notes: [String]
}

/// Installs, updates and moves to the Trash the catalog's Mac apps by the rules of `subset install`, `subset update` and
/// `subset uninstall` (SET-230, SET-231), with the same lock, hidden names and receipts, so the command and this app can
/// take turns on one app:
///   1. download the channel's image into a new private folder (mode 0700) and check its SHA-256;
///   2. attach it read-only and hidden, and require exactly one `.app` at its root, named `<appName>.app`;
///   3. copy it with ditto to a hidden staging name in the destination and clear its ACLs and user file flags;
///   4. verify the staged copy (AppVerifying);
///   5. install: rename it to `<appName>.app`, never over anything, and rename its receipt into place;
///      update: rename the installed copy aside (it must still be the copy checked), rename the new one into place,
///      write the receipt, and only then move the old copy to the Trash.
/// Step 5 is synchronous, so nothing in this app runs between its renames. A failure or a cancel before it removes the
/// staged copy and writes no receipt; the private folder goes once the image is detached. So the old app or the new
/// verified one is always in place: only a crash between the two renames of an update can leave `<appName>.app`
/// missing, and then the next install, update or move to the Trash (here or by `subset`) renames the copy back.
/// No downgrade, no administrator rights, nothing deleted permanently. A running app is quit (terminate(), never a
/// force quit) only when the caller says the user agreed, and is reopened after an update.
public struct AppInstaller: Sendable {
    public static let downloadPrefix = "https://github.com/21nCo/subset/releases/download/"
    /// The copying tool (tests give a wrapper that can be held mid-copy).
    var ditto = "/usr/bin/ditto"
    /// Run just before and right after an update renames the verified copy into place (tests change what is there then).
    var beforePlacing: @Sendable (URL) -> Void = { _ in }
    var afterPlacing: @Sendable (URL) -> Void = { _ in }

    public var setup: InstallSetup
    public var downloader: any ImageDownloading
    public var images: any DiskImageAttaching
    public var verifier: any AppVerifying
    public var trash: any Trashing
    public var running: any RunningAppControlling
    public var clock: @Sendable () -> Date
    /// How long an app asked to quit has to exit.
    public var quitTimeout: TimeInterval
    /// The executable of this running Subset app: a copy holding it is never replaced or moved, because quitting it
    /// would end the operation (tests give another path).
    public var ownExecutable: String?

    public init(
        setup: InstallSetup, downloader: any ImageDownloading = URLSessionImageDownloader(),
        images: any DiskImageAttaching = HdiutilDiskImages(), verifier: any AppVerifying = SecurityAppVerifier(),
        trash: any Trashing = SystemTrash(), running: any RunningAppControlling = WorkspaceRunningApps(),
        clock: @escaping @Sendable () -> Date = Date.init, quitTimeout: TimeInterval = 10,
        ownExecutable: String? = WorkspaceRunningApps.ownExecutable()
    ) {
        self.setup = setup
        self.downloader = downloader
        self.images = images
        self.verifier = verifier
        self.trash = trash
        self.running = running
        self.clock = clock
        self.quitTimeout = quitTimeout
        self.ownExecutable = ownExecutable
    }

    var finder: InstalledAppFinder { InstalledAppFinder(folders: setup.folders, receipts: setup.receipts) }

    /// Whether some installed copy of `app` is running, so the caller can ask before updating or moving it. Throws when
    /// that cannot be read, or when a copy is this running Subset app; the operation itself then refuses with that reason.
    public func isRunning(_ app: CatalogApp) throws -> Bool {
        let copies = finder.copies(of: app)
        try refuseOwnCopy(copies, app, doing: "changed")
        return try copies.contains { try !running.processes(inside: URL(fileURLWithPath: $0.path)).isEmpty }
    }

    /// Refuses, before anything changes, when one of `copies` holds this running Subset app: it cannot be quit for the
    /// swap or the move without ending the operation, so the `subset` command has to do it.
    func refuseOwnCopy(_ copies: [InstalledCopy], _ app: CatalogApp, doing: String) throws {
        guard let ownExecutable else { return }
        // Compared as given and with every link resolved (realpath), on both sides.
        let own = Set([ownExecutable, Self.realPath(ownExecutable)].compactMap { $0 })
        for copy in copies {
            let roots = Set([copy.path, Self.realPath(copy.path)].compactMap { $0 }).map { $0 + "/" }
            if own.contains(where: { path in roots.contains { path.hasPrefix($0) } }) {
                throw InstallFailure(.running, "\(copy.path) is this running \(app.name) app, which cannot quit itself to be \(doing); quit it and use the subset command in Terminal")
            }
        }
    }

    // MARK: - Install

    /// Installs `release` of `app` into /Applications when it is writable, otherwise ~/Applications.
    public func install(_ app: CatalogApp, _ release: ChosenRelease, progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }) async throws -> InstallOutcome {
        try await locked(app) { notes in
            let copies = finder.copies(of: app)
            if let newer = Self.downgrade(copies, release) {
                throw InstallFailure(.downgrade, "\(newer), and Subset does not downgrade")
            }
            let folder = try destination()
            let target = folder.directory.appendingPathComponent("\(app.appName).app")
            if Self.identity(target) != nil {
                throw InstallFailure(.install, "\(target.path) already exists; use Update to change its version")
            }
            let receipt = ReceiptDocument(app, release, folder: folder, receipts: setup.receipts)
            try await stage(app, release, in: folder.directory, notes: notes, progress: progress, ready: {}) { staged in
                try commitInstall(staged, target: target, receipt: receipt)
            }
            if receipt != nil, let other = copies.first(where: { $0.folder != folder.label }) {
                notes.add("\(app.name) \(other.versionLabel) is also installed in \(other.folder); the receipt now describes the copy in \(folder.label).")
            }
            return target.path
        }
    }

    // MARK: - Update

    /// Updates each installed copy of `app` that is older than `release` (UpdateRule), replacing it only once the new
    /// copy is verified. A running copy is quit just before the swap when `quitAllowed`, otherwise the update is refused.
    public func update(
        _ app: CatalogApp, _ release: ChosenRelease, quitAllowed: Bool, progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> InstallOutcome {
        try await locked(app) { notes in
            let (copies, identities, _) = try checkedCopies(app)
            let updates = copies.filter { UpdateRule.decide($0, app, channel: release.channel) == .update }
            guard !updates.isEmpty else {
                throw InstallFailure(.install, "no installed copy of \(app.name) is older than \(release.label)")
            }
            try refuseOwnCopy(updates, app, doing: "updated")
            for copy in updates {
                let target = URL(fileURLWithPath: copy.path)
                let identity = identities[copy.path]!
                if !quitAllowed, try !running.processes(inside: target).isEmpty {
                    throw InstallFailure(.running, "\(app.name) is running; quit it to update it")
                }
                let folder = setup.folders.first { $0.label == copy.folder }
                let receipt = folder.flatMap { ReceiptDocument(app, release, folder: $0, receipts: setup.receipts) }
                // The receipt as it is before this copy is updated (nil when there is none), put back if the update is undone.
                let previousReceipt = receipt.flatMap { try? Data(contentsOf: $0.file) }
                var quit = false
                var old: URL?
                var placed: FileIdentity?
                var trashedAt: Date?
                do {
                    try await stage(app, release, in: target.deletingLastPathComponent(), notes: notes, progress: progress, ready: {
                        let pids = try running.processes(inside: target)
                        guard !pids.isEmpty else { return }
                        guard quitAllowed else { throw InstallFailure(.running, "\(app.name) is running (\(Self.pids(pids))); quit it to update it") }
                        guard Self.identity(target) == identity else {
                            throw InstallFailure(.running, "\(copy.path) was replaced since it was checked, so it was not quit or updated")
                        }
                        // A cancel once the copy is verified quits nothing.
                        try Task.checkCancellation()
                        progress(.quitting)
                        let (left, asked) = try await running.quit(target, timeout: quitTimeout) { Self.identity(target) == identity }
                        // Only an app that was asked to quit is reopened.
                        quit = asked
                        try Task.checkCancellation()
                        try Self.refuseLeft(left, asked: asked, app, at: copy.path, quitTimeout)
                    }) { staged in
                        (old, placed) = try swap(staged, target: target, identity: identity, appName: app.appName, receipt: receipt, notes: notes)
                    }
                    // Cleanup ran after the swap: the verified copy must still be in place before the previous one goes,
                    // checked once everything before the move to the Trash has run.
                    if let old, let placed {
                        progress(.movingToTrash)
                        trashedAt = clock()
                        if Self.identity(target) != placed {
                            try keepPrevious(old, target: target, appName: app.appName, receipt: receipt, previousReceipt: previousReceipt, notes: notes)
                        }
                    }
                } catch {
                    if quit {
                        // Quitting is said even when the update then failed or was cancelled (it changed no copy). Only
                        // the copy that was quit is opened again, never something put at its path since.
                        if let why = await running.reopen(target, isExpected: { Self.identity(target) == identity }) {
                            notes.add("\(app.name) was quit for the update and was not reopened as the copy checked (\(why)).", quit: true)
                        } else {
                            notes.add("\(app.name) was asked to quit for the update and was reopened.", quit: true)
                        }
                    }
                    throw error
                }
                notes.add("Updated the copy in \(copy.folder) from \(copy.versionLabel) to \(release.label).", changed: true, onlyWhenPartial: true)
                if let old {
                    do {
                        let trashed = try trash.trash(old, appName: app.appName, at: trashedAt ?? clock())
                        notes.add("Moved \(app.name) \(copy.versionLabel) (\(copy.folder)) to the Trash: \(trashed.url.path)")
                        if let hidden = trashed.hiddenNote { notes.add(hidden) }
                    } catch let failure as InstallFailure {
                        notes.add("The previous copy could not be moved to the Trash (\(failure.message)); it is at \(old.path).")
                    }
                }
                // Only the verified copy put in place is opened, never something put at its path since.
                if quit, let why = await running.reopen(target, isExpected: { [placed] in placed != nil && Self.identity(target) == placed }) {
                    notes.add("\(app.name) could not be reopened as the copy checked (\(why)).")
                }
            }
            return updates.last.map(\.path)
        }
    }

    // MARK: - Move to Trash

    /// Moves every installed copy of `app` to the Trash and removes its receipt; its data stays. A running copy is quit
    /// first when `quitAllowed`, otherwise nothing is moved.
    public func moveToTrash(
        _ app: CatalogApp, quitAllowed: Bool, progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> InstallOutcome {
        try await locked(app) { notes in
            let (copies, identities, before) = try checkedCopies(app)
            try refuseOwnCopy(copies, app, doing: "moved to the Trash")
            // Every copy is checked, and quit when allowed, before any is moved.
            for copy in copies {
                let bundle = URL(fileURLWithPath: copy.path)
                let pids = try running.processes(inside: bundle)
                guard !pids.isEmpty else { continue }
                guard quitAllowed else { throw InstallFailure(.running, "\(app.name) is running from \(copy.path); quit it to move it to the Trash") }
                guard Self.identity(bundle) == identities[copy.path] else {
                    throw InstallFailure(.trash, "\(copy.path) was replaced since it was checked, so it was not quit or moved")
                }
                // A cancel during one quit starts no other.
                try Task.checkCancellation()
                progress(.quitting)
                let checked = identities[copy.path]
                let (left, asked) = try await running.quit(bundle, timeout: quitTimeout) { Self.identity(bundle) == checked }
                // Quitting is said even when nothing is moved afterwards; it changes no copy.
                if asked { notes.add("\(app.name) at \(copy.path) was asked to quit.", quit: true, onlyWhenPartial: true) }
                try Task.checkCancellation()
                try Self.refuseLeft(left, asked: asked, app, at: copy.path, quitTimeout)
            }
            progress(.movingToTrash)
            for copy in copies {
                try Task.checkCancellation()
                let bundle = URL(fileURLWithPath: copy.path)
                if try !running.processes(inside: bundle).isEmpty {
                    throw InstallFailure(.running, "\(app.name) is running from \(copy.path) again; quit it and try again")
                }
                let aside = AppLock.hiddenName(in: bundle.deletingLastPathComponent(), appName: app.appName, kind: "trash")
                guard renamex_np(bundle.path, aside.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw InstallFailure(.trash, "\(copy.path) cannot be set aside to move it to the Trash (\(Self.errnoText()))")
                }
                guard Self.identity(aside) == identities[copy.path] else {
                    throw InstallFailure(.trash, "\(copy.path) was replaced since it was checked, so it was left in place\(Self.putBack(aside, bundle, notes))")
                }
                do {
                    let trashed = try trash.trash(aside, appName: app.appName, at: clock())
                    notes.add("Moved \(app.name) \(copy.versionLabel) (\(copy.folder)) to the Trash: \(trashed.url.path)", changed: true)
                    if let hidden = trashed.hiddenNote { notes.add(hidden, changed: true) }
                } catch let failure as InstallFailure {
                    throw InstallFailure(.trash, failure.message + Self.putBack(aside, bundle, notes))
                }
            }
            // The receipt goes only when no copy that is or may be the app is in either folder any more, decided as
            // `subset uninstall` decides it (receiptDecision).
            let file = setup.receipts.appendingPathComponent("\(app.bundleID).json")
            let (again, maybe) = receiptDecision(app, moved: Set(identities.keys), before: before)
            if !maybe.isEmpty {
                let each = maybe.map { "\($0.path) was not moved to the Trash: it may be \(app.name) (\($0.why))" }.joined(separator: "; ")
                throw InstallFailure(.trash, "\(each), so the receipt \(file.path) stays; remove the receipt by hand if that is not \(app.name)")
            }
            if !again.isEmpty {
                for path in again { notes.add("\(path) was installed again while \(app.name) was moved to the Trash, so its receipt stays.") }
            } else if unlink(file.path) != 0, errno != ENOENT, errno != ENAMETOOLONG {
                notes.add("Its receipt \(file.path) could not be removed (\(Self.errnoText())); remove it by hand.")
            }
            return nil
        }
    }

    // MARK: - Steps

    /// Takes the app's lock, puts back what an interrupted update or move to the Trash left, runs `body` and releases the
    /// lock. A cancel is reported as interrupted, and an unexpected error as a failure.
    /// A failure carries the notes collected so far and whether something was already changed (`partial`).
    private func locked(_ app: CatalogApp, _ body: (Notes) async throws -> String?) async throws -> InstallOutcome {
        let notes = Notes()
        do {
            try Task.checkCancellation()
            let lock = try AppLock(app, in: setup.locks)
            defer { lock.release() }
            // Putting back or renaming what an interrupted operation left is a change, even if this one then fails.
            for note in recover(app) { notes.add(note.line, recovered: note.changed) }
            let path = try await body(notes)
            return InstallOutcome(path: path, notes: notes.lines)
        } catch {
            var failure: InstallFailure
            switch error {
            case let known as InstallFailure: failure = known
            case is CancellationError:
                failure = InstallFailure(.interrupted, notes.changed ? "it was cancelled after part of it was done"
                    : notes.recovered ? "it was cancelled before anything else was changed"
                    : notes.quit ? "it was cancelled after the app was asked to quit, before any copy was changed"
                    : "it was cancelled before anything was changed")
            default: failure = InstallFailure(.install, error.localizedDescription)
            }
            failure.partial = notes.changed || notes.recovered
            failure.onlyRecovered = !notes.changed && notes.recovered
            failure.notes = failure.partial || notes.quit ? notes.partialLines : notes.lines
            throw failure
        }
    }

    /// What each folder's `<appName>.app` says about the receipt after the moves, each looked at as `subset uninstall`
    /// looks (uninstall.mjs):
    /// - absent, or not this app: an entry unchanged (device and inode) since the copies were identified that is a link,
    ///   a file, a folder without a Contents folder or Contents/Info.plist file, or another app;
    /// - installed again: something at a moved copy's path, or new or changed since the copies were identified, or
    ///   replaced while it was looked into;
    /// - maybe this app: an unchanged bundle folder (not a link) whose folder or Contents cannot be looked into, whose
    ///   Info.plist cannot be read, or whose Info.plist names this bundle ID, or an entry that cannot be looked at.
    func receiptDecision(_ app: CatalogApp, moved: Set<String>, before: [String: FileIdentity?]) -> (again: [String], maybe: [(path: String, why: String)]) {
        var again: [String] = []
        var maybe: [(path: String, why: String)] = []
        for folder in setup.folders {
            let bundle = folder.directory.appendingPathComponent("\(app.appName).app").path
            let current: Entry
            switch Self.look(bundle) {
            case .failed(let why):
                maybe.append((bundle, "it could not be looked into: \(why)"))
                continue
            case .absent: continue
            case .present(let entry): current = entry
            }
            if moved.contains(bundle) || (before[bundle] ?? nil) != current.identity {
                again.append(bundle)
                continue
            }
            let reason = current.isDirectory ? mayBeApp(bundle, app) : nil
            // Looked at again: removed while it was looked into, it is absent; replaced, what is there now was not.
            switch Self.look(bundle) {
            case .failed(let why): maybe.append((bundle, "it could not be looked into: \(why)"))
            case .absent: continue
            case .present(let after):
                if after.identity != current.identity { again.append(bundle) } else if let reason { maybe.append((bundle, reason)) }
            }
        }
        return (again, maybe)
    }

    /// Why an unchanged bundle folder may be `app`, or nil when it is not (uninstall.mjs mayBeApp).
    func mayBeApp(_ bundle: String, _ app: CatalogApp) -> String? {
        for (file, kind) in [("\(bundle)/Contents", S_IFDIR), ("\(bundle)/Contents/Info.plist", S_IFREG)] {
            switch Self.look(file) {
            case .failed(let why): return "\(file) could not be looked into: \(why)"
            case .absent: return nil
            case .present(let entry) where entry.type != kind: return nil
            case .present: continue
            }
        }
        guard let info = InstalledAppFinder.infoPlist(bundle) else { return "its Info.plist could not be read" }
        return info["CFBundleIdentifier"] as? String == app.bundleID ? "its Info.plist names \(app.bundleID)" : nil
    }

    /// One lstat of a path: what is there (never following a link), nothing, or why it cannot be seen.
    enum Look {
        case absent
        case present(Entry)
        case failed(String)
    }

    struct Entry {
        var identity: FileIdentity
        var type: mode_t
        var isDirectory: Bool { type == S_IFDIR }
    }

    static func look(_ path: String) -> Look {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .failed(errnoText())
        }
        return .present(Entry(identity: FileIdentity(device: status.st_dev, inode: status.st_ino), type: status.st_mode & S_IFMT))
    }

    /// The installed copies of `app`, each identified (device and inode) before and after its Info.plist was read; throws
    /// when one was replaced in between (its version may not be its own) or none is installed.
    /// Also returns each folder's `<appName>.app` identity (nil when absent) from before the copies were read.
    private func checkedCopies(_ app: CatalogApp) throws -> ([InstalledCopy], [String: FileIdentity], [String: FileIdentity?]) {
        let bundles = setup.folders.map { $0.directory.appendingPathComponent("\(app.appName).app") }
        let before = Dictionary(uniqueKeysWithValues: bundles.map { ($0.path, Self.identity($0)) })
        let copies = finder.copies(of: app)
        guard !copies.isEmpty else { throw InstallFailure(.notInstalled, "\(app.name) is not installed in /Applications or ~/Applications") }
        var identities: [String: FileIdentity] = [:]
        for copy in copies {
            guard let now = Self.identity(URL(fileURLWithPath: copy.path)), before[copy.path] == now else {
                throw InstallFailure(.install, "\(copy.path) was replaced while its version was read; try again")
            }
            identities[copy.path] = now
        }
        return (copies, identities, before)
    }

    /// Steps 1 to 4 and then `ready` and `commit` (step 5, synchronous), with the cleanup of a failure or cancel.
    private func stage(
        _ app: CatalogApp, _ release: ChosenRelease, in dir: URL, notes: Notes, progress: @escaping @Sendable (InstallProgress) -> Void,
        ready: () async throws -> Void, commit: (URL) throws -> Void
    ) async throws {
        guard release.url.hasPrefix(Self.downloadPrefix), let url = URL(string: release.url) else {
            throw InstallFailure(.download, "the feed's download URL is not a \(Self.downloadPrefix) URL")
        }
        var template = Array(setup.temporary.appendingPathComponent("subset-install-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw InstallFailure(.download, "a private folder cannot be made (\(Self.errnoText()))") }
        let work = URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        let mountRoot = work.appendingPathComponent("mnt")
        let image = work.appendingPathComponent("image.dmg")
        let staged = dir.appendingPathComponent(".\(app.appName).app.subset-install-\(AppLock.random())")
        var step = InstallFailure.Step.download
        var attachTried = false
        var devices: [String] = []
        var stagedCreated = false
        var installed = false
        do {
            guard mkdir(mountRoot.path, 0o700) == 0 else { throw InstallFailure(.download, "\(mountRoot.path) cannot be made (\(Self.errnoText()))") }
            try Task.checkCancellation()
            progress(.downloading(received: 0, total: nil))
            try await downloader.download(url, to: image) { progress(.downloading(received: $0, total: $1)) }
            try Task.checkCancellation()
            step = .checksum
            let digest = try Self.sha256(of: image)
            guard digest == release.sha256 else {
                throw InstallFailure(.checksum, "the download's SHA-256 is \(digest), not \(release.sha256) as the feed lists")
            }

            step = .image
            attachTried = true
            devices = try await images.attach(image, mountRoot: mountRoot)
            try Task.checkCancellation()
            let source = try Self.findApp(in: mountRoot, appName: app.appName)

            step = .copy
            guard mkdir(staged.path, 0o700) == 0 else { throw InstallFailure(.copy, "\(staged.path) cannot be made (\(Self.errnoText()))") }
            stagedCreated = true
            let copy = try await ToolRunner.run(ditto, [source.path, staged.path], timeout: 600)
            guard copy.status == 0 else { throw InstallFailure(.copy, "ditto could not copy \(app.appName).app into \(dir.path) (\(copy.lastLine))") }
            // The installed app carries no deny-delete ACL or immutable flag from the image, so it can be updated and removed.
            if let why = try await Self.clearProtections(staged, cancellable: true) {
                throw InstallFailure(.copy, "the ACLs and file flags of the copy in \(dir.path) cannot be cleared (\(why))")
            }
            var status = stat()
            lstat(source.path, &status)
            let mode = status.st_mode & 0o755

            step = .signature
            progress(.verifying)
            try await verifier.verify(staged, expected: ExpectedApp(bundleID: app.bundleID, version: release.version, build: release.build))
            try await ready()

            step = .install
            try Task.checkCancellation()
            progress(.installing)
            chmod(staged.path, mode)
            try commit(staged)
            installed = true
        } catch {
            let left = await cleanup(work: work, mountRoot: mountRoot, image: image, attachTried: attachTried, devices: devices, staged: stagedCreated && !installed ? staged : nil)
            var failure: InstallFailure
            switch error {
            case let known as InstallFailure: failure = known
            case is CancellationError: failure = InstallFailure(.interrupted, "it was cancelled before it was installed")
            default: failure = InstallFailure(step, error.localizedDescription)
            }
            if !left.isEmpty { failure.message += "; " + left.joined(separator: "; ") }
            throw failure
        }
        for line in await cleanup(work: work, mountRoot: mountRoot, image: image, attachTried: attachTried, devices: devices, staged: nil) {
            notes.add(line)
        }
    }

    /// Removes the staged copy (when given), detaches the image and removes the private folder once the image is no longer
    /// attached. Never cancelled. Returns what could not be cleaned up.
    private func cleanup(work: URL, mountRoot: URL, image: URL, attachTried: Bool, devices: [String], staged: URL?) async -> [String] {
        var left: [String] = []
        if let staged, !(await Self.removeStaged(staged)) {
            left.append("the staged copy \(staged.path) could not be removed; remove it by hand")
        }
        if attachTried, !(await images.detach(image, devices: devices)) {
            left.append("the disk image \(image.path) could not be detached; it stays attached, with the folder \(work.path)")
            return left
        }
        // The mount folders hdiutil made must be empty, so nothing still mounted is touched.
        let mounts = (try? FileManager.default.contentsOfDirectory(atPath: mountRoot.path)) ?? []
        let emptied = mounts.allSatisfy { rmdir(mountRoot.appendingPathComponent($0).path) == 0 }
        if !emptied || (try? FileManager.default.removeItem(at: work)) == nil {
            left.append("the folder \(work.path) could not be removed; remove it by hand")
        }
        return left
    }

    /// Step 5 of an install: the staged copy is renamed to `target`, never over anything, and its receipt renamed into
    /// place; when the receipt cannot be, the app is taken back out (no app without its receipt).
    private func commitInstall(_ staged: URL, target: URL, receipt: ReceiptDocument?) throws {
        let taken = InstallFailure(.install, "\(target.path) already exists; use Update to change its version")
        let temporary = try receipt?.writeTemporary(installedAt: clock())
        guard renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if let temporary { unlink(temporary.path) }
            if code == EEXIST { throw taken }
            throw InstallFailure(.install, "\(target.lastPathComponent) cannot be renamed into place (\(String(cString: strerror(code))))")
        }
        guard let temporary, let receipt else { return }
        guard rename(temporary.path, receipt.file.path) == 0 else {
            let reason = "the receipt \(receipt.file.path) cannot be written (\(Self.errnoText()))"
            unlink(temporary.path)
            if renamex_np(target.path, staged.path, UInt32(RENAME_EXCL)) == 0 { throw InstallFailure(.receipt, reason) }
            throw InstallFailure(.receipt, "\(reason), and \(target.path) could not be taken back out; remove it by hand")
        }
    }

    /// Step 5 of an update (swapApp in update.mjs): `target`, still `identity`, is renamed aside, the verified copy renamed
    /// into place and the old one renamed to a hidden `old` name that is never put back; then the receipt is written.
    /// Returns the old copy and the identity of the new one in place. Throws leaving `target` as it was and `staged` where
    /// it was, or, when what is at `target` right after the rename is not the verified copy, leaving that as it is, the
    /// receipt unchanged and the previous copy put back (when nothing is there) or kept under its hidden name.
    private func swap(
        _ staged: URL, target: URL, identity: FileIdentity, appName: String, receipt: ReceiptDocument?, notes: Notes
    ) throws -> (old: URL, placed: FileIdentity) {
        let dir = target.deletingLastPathComponent()
        let backup = AppLock.hiddenName(in: dir, appName: appName, kind: "update")
        let changed = "\(target.path) was changed or removed while it was being updated (by the subset command?)"
        guard renamex_np(target.path, backup.path, UInt32(RENAME_EXCL)) == 0 else {
            throw InstallFailure(.install, errno == ENOENT ? changed : "\(target.path) cannot be moved aside (\(Self.errnoText()))")
        }
        guard Self.identity(backup) == identity else { throw InstallFailure(.install, changed + Self.putBack(backup, target, notes)) }
        // The verified copy, identified before its rename: what is at `target` afterwards is it only when it matches.
        let verified = Self.identity(staged)
        beforePlacing(target)
        guard renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw InstallFailure(.install, "the new copy cannot be renamed into place (\(Self.errnoText()))\(Self.putBack(backup, target, notes))")
        }
        afterPlacing(target)
        // The new receipt is written aside first; nothing is changed by it until the copy in place is checked below.
        var temporary: URL?
        var receiptFailure: String?
        if let receipt {
            do {
                temporary = try receipt.writeTemporary(installedAt: clock())
            } catch let failure as InstallFailure {
                receiptFailure = failure.message
            }
        }
        // Only the verified copy at `target`, checked after everything that can wait, makes this an update: anything else
        // there (or nothing) is left as it is, the receipt is not touched and the previous copy is not disposed of.
        guard let verified, Self.identity(target) == verified else {
            if let temporary { unlink(temporary.path) }
            let why = "\(target.path) was changed or removed right after the new copy was put there (by the subset command?)"
            if Self.identity(target) == nil, renamex_np(backup.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                throw InstallFailure(.install, "\(why), so the previous copy was put back")
            }
            notes.add("The previous copy of \(appName) is kept at \(backup.path); rename it to \(target.path) to use it again.", changed: true)
            throw InstallFailure(.install, "\(why), so it was left as it is and the receipt was not changed")
        }
        // A receipt is advisory: when it cannot be written, the one there (describing the old copy) is removed.
        if let receipt {
            if let temporary, rename(temporary.path, receipt.file.path) == 0 {
                // Written.
            } else {
                if let temporary { unlink(temporary.path) }
                unlink(receipt.file.path)
                notes.add(receiptFailure.map { "\($0); the app is updated without one." } ?? "The receipt \(receipt.file.path) was not written; the app is updated without one.")
            }
        }
        var old = AppLock.hiddenName(in: dir, appName: appName, kind: "old")
        if renamex_np(backup.path, old.path, UInt32(RENAME_EXCL)) != 0 { old = backup }
        return (old, verified)
    }

    /// After an update's swap, `target` no longer holds the verified copy (changed or removed while the image was
    /// cleaned up): the receipt is put back as it was before (`previousReceipt`, or none), and the previous copy, `old`,
    /// is put back when nothing is at `target`, otherwise kept where it is and named. Always throws, saying what
    /// happened; it is a change only when the previous copy stays aside or the receipt cannot be put back.
    private func keepPrevious(
        _ old: URL, target: URL, appName: String, receipt: ReceiptDocument?, previousReceipt: Data?, notes: Notes
    ) throws {
        let why = "\(target.path) was changed or removed after the new copy was put there (by the subset command?)"
        if let receipt {
            let restored = previousReceipt.map { (try? $0.write(to: receipt.file, options: .atomic)) != nil }
                ?? (unlink(receipt.file.path) == 0 || errno == ENOENT)
            if !restored {
                notes.add("The receipt \(receipt.file.path), written for the new copy, could not be put back as it was (\(Self.errnoText())).", changed: true)
            }
        }
        if Self.identity(target) == nil, renamex_np(old.path, target.path, UInt32(RENAME_EXCL)) == 0 {
            throw InstallFailure(.install, "\(why), so the previous copy and its receipt were put back")
        }
        notes.add("The previous copy of \(appName) is kept at \(old.path); rename it to \(target.path) to use it again.", changed: true)
        throw InstallFailure(.install, "\(why), so it was left as it is and the previous copy was kept")
    }

    /// What an interrupted update or move to the Trash (here or by `subset`) left beside `<appName>.app` under a hidden
    /// name, handled as recoverApps in update.mjs does: when `<appName>.app` is missing and exactly one `update` or `trash`
    /// copy of a process that no longer runs is there, it is renamed back; when `<appName>.app` is there, such copies are
    /// renamed to `old` names. `old` copies are never put back, only named. Staged copies are never touched.
    /// Each note says whether it reports a rename made here (`changed`).
    func recover(_ app: CatalogApp) -> [(line: String, changed: Bool)] {
        let escaped = NSRegularExpression.escapedPattern(for: app.appName)
        guard let pattern = try? NSRegularExpression(pattern: #"^\.\#(escaped)\.app\.subset-(update|trash|old)-([0-9]+)-[0-9a-f]{12}$"#) else { return [] }
        var notes: [(line: String, changed: Bool)] = []
        for folder in setup.folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.directory.path)) ?? []
            let found = names.compactMap { name -> (file: URL, kind: String, pid: pid_t)? in
                guard let match = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                      let kind = Range(match.range(at: 1), in: name), let pid = Range(match.range(at: 2), in: name)
                else { return nil }
                return (folder.directory.appendingPathComponent(name), String(name[kind]), pid_t(name[pid]) ?? 0)
            }
            guard !found.isEmpty else { continue }
            let target = folder.directory.appendingPathComponent("\(app.appName).app")
            var present = Self.identity(target) != nil
            if present, !BoundedFile.isDirectory(target.path) {
                // Not an app folder (a link or a file): nothing is put back over it or renamed beside it, only named.
                notes.append(("\(target.path) is not an app folder, and an interrupted update or move to the Trash left copies of \(app.name) beside it at \(found.map(\.file.path).joined(separator: ", ")).", false))
                continue
            }
            let busy = found.first { $0.pid != getpid() && AppLock.processRuns($0.pid) }
            let unfinished = found.filter { $0.kind != "old" }
            if !present, !unfinished.isEmpty {
                if busy == nil, unfinished.count == 1, BoundedFile.isDirectory(unfinished[0].file.path),
                   renamex_np(unfinished[0].file.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                    notes.append(("\(app.name) was put back at \(target.path): an interrupted update had left it at \(unfinished[0].file.path).", true))
                    present = true
                } else {
                    notes.append(("\(app.name) is missing from \(folder.label), and an interrupted update left it at \(unfinished.map(\.file.path).joined(separator: ", ")); rename the copy to keep to \(target.path).", false))
                    continue
                }
            }
            if busy != nil { continue }
            var renamed = false
            let left = found.filter { Self.identity($0.file) != nil }.map { entry -> String in
                guard entry.kind != "old" else { return entry.file.path }
                let old = AppLock.hiddenName(in: folder.directory, appName: app.appName, kind: "old")
                guard renamex_np(entry.file.path, old.path, UInt32(RENAME_EXCL)) == 0 else { return entry.file.path }
                renamed = true
                return old.path
            }
            if !left.isEmpty {
                notes.append(("A previous copy of \(app.name) that was not moved to the Trash is at \(left.joined(separator: ", ")); it is not used any more and can be moved to the Trash.", renamed))
            }
        }
        return notes
    }

    /// /Applications when it is a writable folder, otherwise ~/Applications (created when missing).
    private func destination() throws -> ApplicationsFolder {
        let system = setup.folders[0]
        let user = setup.folders[1]
        let writable = { (url: URL) in access(url.path, W_OK) == 0 && FileManager.default.isDirectory(url) }
        if writable(system.directory) { return system }
        do {
            try FileManager.default.createDirectory(at: user.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        } catch {
            throw InstallFailure(.destination, "\(user.directory.path) cannot be created (\(error.localizedDescription))")
        }
        guard writable(user.directory) else { throw InstallFailure(.destination, "\(user.directory.path) is not a writable folder") }
        return user
    }

    // MARK: - Helpers

    /// Why installing `release` would be a downgrade of an installed copy, or nil.
    static func downgrade(_ copies: [InstalledCopy], _ release: ChosenRelease) -> String? {
        for copy in copies {
            guard let version = copy.version, FeedPattern.version.matches(version) else { continue }
            let order = UpdateRule.compareVersions(release.version, version)
            var olderBuild = false
            if order == 0, let build = release.build, let copyBuild = copy.build, !copyBuild.isEmpty,
               copyBuild.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
                olderBuild = UpdateRule.compareNumbers(copyBuild, String(build)) > 0
            }
            if order < 0 || olderBuild {
                return "\(InstalledCopy.displayable(version))\(olderBuild ? " (build \(InstalledCopy.displayable(copy.build ?? "")))" : "") is installed in \(copy.folder)"
            }
        }
        return nil
    }

    /// The one volume the image mounted in `mountRoot`, and in it the one app, which must be `<appName>.app`.
    static func findApp(in mountRoot: URL, appName: String) throws -> URL {
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: mountRoot.path)) ?? []
        guard volumes.count == 1 else { throw InstallFailure(.image, "the image mounted \(volumes.count) volumes, not one") }
        let volume = mountRoot.appendingPathComponent(volumes[0])
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: volume.path)) ?? []).filter { $0.lowercased().hasSuffix(".app") }
        let expected = "\(appName).app"
        guard apps.count == 1 else { throw InstallFailure(.image, "the image holds \(apps.count) apps at its root, not exactly one (\(expected))") }
        guard apps[0] == expected else { throw InstallFailure(.image, "the image holds \"\(InstalledCopy.displayable(apps[0]))\", not \(expected)") }
        let source = volume.appendingPathComponent(expected)
        guard BoundedFile.isDirectory(source.path) else { throw InstallFailure(.image, "\(expected) in the image is not a folder") }
        return source
    }

    /// Clears the user file flags that block removal (uchg, uappnd) and the ACLs of everything in `tree`, never following
    /// a symbolic link. Returns the first failure, or nil.
    static func clearProtections(_ tree: URL, cancellable: Bool) async throws -> String? {
        for (tool, change) in [("/usr/bin/chflags", ["-h", "nouchg,nouappnd"]), ("/bin/chmod", ["-h", "-N"])] {
            let run = try await ToolRunner.run("/usr/bin/find", ["-P", tree.path, "-exec", tool] + change + ["{}", "+"], timeout: 120, cancellable: cancellable)
            if run.status != 0 { return "\((tool as NSString).lastPathComponent): \(run.lastLine)" }
        }
        return nil
    }

    /// Removes a staged copy whatever ditto copied from the image: flags and ACLs cleared and folders made writable, in up
    /// to three passes. Never cancelled. Returns whether it is gone.
    static func removeStaged(_ staged: URL) async -> Bool {
        for _ in 0..<3 {
            if identity(staged) == nil { return true }
            _ = try? await clearProtections(staged, cancellable: false)
            var pending = [staged.path]
            while let dir = pending.popLast() {
                var status = stat()
                guard lstat(dir, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { continue }
                if status.st_mode & 0o700 != 0o700 { chmod(dir, (status.st_mode & 0o7777) | 0o700) }
                pending += ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { "\(dir)/\($0)" }
            }
            if (try? FileManager.default.removeItem(at: staged)) != nil { return true }
        }
        return identity(staged) == nil
    }

    static func sha256(of file: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { throw InstallFailure(.checksum, "the download cannot be read") }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The device and inode of whatever is at `url` (not following a link), or nil when nothing is.
    static func identity(_ url: URL) -> FileIdentity? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    /// Renames `from` back to `to` after a failed step; returns what to add to the message when that fails too, and then
    /// counts the copy left aside as a change in `notes`.
    static func putBack(_ from: URL, _ to: URL, _ notes: Notes) -> String {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return "" }
        let why = errnoText()
        notes.copyLeftAside()
        return ", and the previous copy could not be put back (\(why)): it is at \(from.path); rename it to \(to.path)"
    }

    /// `path` with every link resolved, or nil when it cannot be (it does not exist).
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func pids(_ pids: [pid_t]) -> String { "pid " + pids.map(String.init).joined(separator: ", ") }

    /// Refuses when processes of the copy still run after the quit: helpers alone (no app to ask, and force quit is never
    /// used), or an app that did not exit in time.
    static func refuseLeft(_ left: [pid_t], asked: Bool, _ app: CatalogApp, at path: String, _ timeout: TimeInterval) throws {
        guard !left.isEmpty else { return }
        guard asked else {
            throw InstallFailure(.running, "a helper process of \(app.name) runs from \(path) (\(pids(left))) and Subset asks only apps to quit; quit it and try again")
        }
        throw InstallFailure(.running, "\(app.name) is still running \(Int(timeout)) seconds after it was asked to quit (\(pids(left)))")
    }

    static func errnoText() -> String { String(cString: strerror(errno)) }
}

/// A file's device and inode: the copy checked is the copy changed.
struct FileIdentity: Equatable, Sendable {
    var device: dev_t
    var inode: ino_t
}

/// Notes an operation collects while it runs (on one task at a time), and whether it has changed something yet.
final class Notes: @unchecked Sendable {
    private var entries: [(line: String, onlyWhenPartial: Bool)] = []
    /// Whether it changed an installed copy (updated, moved aside or moved to the Trash).
    private(set) var changed = false
    /// Whether it put back or renamed what an interrupted operation had left (before doing anything itself).
    private(set) var recovered = false
    /// Whether it asked an app to quit; that changes no copy, so it is said without making the result partial.
    private(set) var quit = false

    /// The notes of an operation that finished.
    var lines: [String] { entries.filter { !$0.onlyWhenPartial }.map(\.line) }
    /// The notes of one that failed or was cancelled after changing something: what it changed, too.
    var partialLines: [String] { entries.map(\.line) }

    /// Adds a note; `changed` when it reports a change to a copy, `quit` when it reports an app asked to quit,
    /// `onlyWhenPartial` when it is worth saying only if the operation then fails (a finished one says it in its own
    /// message).
    func add(_ line: String, changed: Bool = false, recovered: Bool = false, quit: Bool = false, onlyWhenPartial: Bool = false) {
        entries.append((line, onlyWhenPartial))
        if changed { self.changed = true }
        if recovered { self.recovered = true }
        if quit { self.quit = true }
    }

    /// A copy was moved aside and could not be put back: a change, which the failure's message describes.
    func copyLeftAside() { changed = true }
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
