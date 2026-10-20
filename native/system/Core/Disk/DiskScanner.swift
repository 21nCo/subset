import Darwin
import Foundation

/// How far a scan has got. Bytes are allocated bytes, folders' own allocation included, with each hard-linked file and
/// folder counted once; clones are resolved only in the final totals, so each copy counts here in full.
public struct DiskScanProgress: Equatable, Sendable {
    public var items: Int
    public var allocatedBytes: UInt64
    /// The folder a worker started reading most recently.
    public var currentPath: String
}

public enum DiskScanError: Error, Equatable, Sendable {
    /// The chosen path does not exist or cannot be resolved (`errno`).
    case cannotResolve(path: String, errno: Int32)
    case notADirectory(String)
    /// The path is on a network or other non-local volume, which is out of scope.
    case notLocal(path: String, fileSystem: String)
}

public struct DiskScanResult: Sendable {
    public enum Outcome: Equatable, Sendable {
        case completed
        /// Cancelled: the tree holds what was read, with unread folders marked `partial`.
        case cancelled
    }

    public let tree: DiskTree
    public let outcome: Outcome
    /// Folders and entries that could not be read, counted with an unknown size, sorted.
    public let unreadablePaths: [String]
    /// Every entry read, including those inside packages, which are not items of the tree.
    public let entriesRead: Int

    /// The root's totals, or `nil` when the root itself could not be read.
    public var totals: DiskSizes? { tree.root.sizes }
}

/// Scans a folder or local volume with `getattrlistbulk`, a small pool of worker threads, and no Full Disk Access
/// requirement. It does not cross mount points or follow symbolic links, counts package bundles as one item, never
/// downloads an iCloud placeholder, and keeps the result in memory only.
public struct DiskScanner: Sendable {
    public static let defaultWorkers = 4
    /// The default scope: the user's home folder.
    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser }

    public let workers: Int
    public let progressInterval: Duration
    let bufferSize: Int
    let isPackage: @Sendable (String) -> Bool
    let mapExtent: PhysicalExtents.Mapper

    public init(workers: Int = DiskScanner.defaultWorkers, progressInterval: Duration = .milliseconds(100)) {
        self.init(workers: workers, progressInterval: progressInterval, bufferSize: 128 << 10,
                  isPackage: DiskScanner.launchServicesIsPackage)
    }

    init(workers: Int, progressInterval: Duration, bufferSize: Int, isPackage: @escaping @Sendable (String) -> Bool,
         mapExtent: @escaping PhysicalExtents.Mapper = PhysicalExtents.logicalToPhysical) {
        self.workers = max(1, workers)
        self.progressInterval = progressInterval
        self.bufferSize = bufferSize
        self.isPackage = isPackage
        self.mapExtent = mapExtent
    }

    /// Scans `root`, calling `onProgress` from a worker thread at most once per `progressInterval`, one call at a time
    /// and with the item count always rising. Cancelling the calling task stops every worker at its next batch of
    /// entries, or at its next call mapping a clone's ranges, and returns what was read. The root is resolved and
    /// classified on a scan thread too, never on the caller's, so no lookup can download a placeholder or hold up the
    /// caller's thread.
    public func scan(_ root: URL = DiskScanner.defaultRoot,
                     onProgress: (@Sendable (DiskScanProgress) -> Void)? = nil) async throws(DiskScanError)
        -> DiskScanResult {
        let lookup = await withCheckedContinuation { (continuation: CheckedContinuation<Result<DiskScan, DiskScanError>, Never>) in
            DiskScan.spawn {
                continuation.resume(returning: Result { () throws(DiskScanError) in
                    DiskScan(scanner: self, rootPath: try Self.resolve(root.path), onProgress: onProgress)
                })
            }
        }
        let scan = try lookup.get()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                scan.start { continuation.resume(returning: $0) }
            }
        } onCancel: {
            scan.cancel()
        }
    }

    /// The real path of a local directory. The chosen root may be reached through a symbolic link; nothing below it is.
    static func resolve(_ path: String) throws(DiskScanError) -> String {
        guard let real = realpath(path, nil) else { throw .cannotResolve(path: path, errno: errno) }
        defer { free(real) }
        let resolved = String(cString: real)
        var info = stat()
        guard stat(resolved, &info) == 0 else { throw .cannotResolve(path: path, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw .notADirectory(resolved) }
        var volume = statfs()
        guard statfs(resolved, &volume) == 0 else { throw .cannotResolve(path: path, errno: errno) }
        guard volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
            let type = withUnsafeBytes(of: volume.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            throw .notLocal(path: resolved, fileSystem: type)
        }
        return resolved
    }

    @Sendable static func launchServicesIsPackage(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage == true
    }
}

/// One running scan: a queue of folders, the workers that read them, and the tree they build.
final class DiskScan: @unchecked Sendable {
    private struct Job {
        let node: Int32
        let path: String
        /// The folder's volume and inode as its entry reported them, checked again once it is opened.
        let identity: FileKey?
        /// Inside a package: entries add to `node`'s total and are not items.
        let inPackage: Bool
        /// The folder is the item `node` itself rather than a folder inside its package, so failing to read it makes
        /// the item's size unknown.
        let isItem: Bool
    }

    private let scanner: DiskScanner
    private let onProgress: (@Sendable (DiskScanProgress) -> Void)?
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var builder: TreeBuilder
    private var queue: [Job]
    private var busy = 0
    private var running = 0
    private var cancelled = false
    private var progress: DiskScanProgress
    private var countedLinks: Set<FileKey> = []
    private var lastPublished: ContinuousClock.Instant?
    private var finish: ((DiskScanResult) -> Void)?
    /// Serializes progress callbacks, which run outside `condition`, so a snapshot older than one delivered is dropped.
    private let delivery = NSLock()
    private var deliveredItems = 0

    init(scanner: DiskScanner, rootPath: String, onProgress: (@Sendable (DiskScanProgress) -> Void)?) {
        self.scanner = scanner
        self.onProgress = onProgress
        let name = rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent
        let root = Self.rootFacts(rootPath, name: name, isPackage: scanner.isPackage)
        var builder = TreeBuilder(rootPath: rootPath, rootName: name, root: root)
        _ = builder.admit(root)
        self.builder = builder
        queue = root.descent.map {
            [Job(node: 0, path: rootPath, identity: root.opensAs, inPackage: $0 == .package, isItem: true)]
        } ?? []
        progress = DiskScanProgress(items: 0, allocatedBytes: root.contribution.allocated, currentPath: rootPath)
    }

    /// Classifies the scanned folder from its own attributes, as its parent would: its allocation counts, a package is
    /// one item, and a placeholder is not read. Its mount status is ignored, since a chosen volume is what is scanned.
    static func rootFacts(_ path: String, name: String, isPackage: (String) -> Bool) -> EntryFacts {
        guard var entry = BulkAttributes.read(path: path), entry.error == 0 || entry.error == EILSEQ else {
            // Its own allocation is unknown, so its totals are a lower bound.
            return EntryFacts(kind: .directory, flags: .incomplete, descent: .folder)
        }
        // A volume's root reports the volume's name; the error was only for a name that is not UTF-8.
        entry.name = name
        entry.error = 0
        entry.objectType = entry.objectType ?? VDIR.rawValue
        entry.mountStatus = nil
        return EntryFacts(entry) { isPackage(path) }
    }

    func start(_ finish: @escaping (DiskScanResult) -> Void) {
        condition.withLock {
            self.finish = finish
            running = scanner.workers
        }
        for _ in 0..<scanner.workers {
            Self.spawn { [self] in work() }
        }
    }

    /// Runs `body` on a new scan thread on which reading a dataless file or folder never downloads it.
    static func spawn(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread {
            setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            body()
        }
        thread.name = "Disk scan"
        thread.qualityOfService = .utility
        thread.start()
    }

    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    private var isCancelled: Bool { condition.withLock { cancelled } }

    private func work() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: scanner.bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        while let job = nextJob() {
            read(job, buffer: buffer)
        }
        let result: DiskScanResult? = condition.withLock {
            running -= 1
            guard running == 0 else { return nil }
            for job in queue {
                builder.insert(.partial, into: job.node)
            }
            queue.removeAll()
            let outcome: DiskScanResult.Outcome = cancelled ? .cancelled : .completed
            let unreadable = builder.unreadablePaths.sorted()
            return DiskScanResult(tree: builder.finish(), outcome: outcome, unreadablePaths: unreadable,
                                  entriesRead: progress.items)
        }
        if let result {
            let finish = condition.withLock { self.finish }
            finish?(result)
        }
    }

    /// The next folder to read, waiting while other workers may still add some; `nil` once the scan is over.
    private func nextJob() -> Job? {
        condition.withLock {
            while queue.isEmpty, busy > 0, !cancelled { condition.wait() }
            guard !cancelled, let job = queue.popLast() else {
                condition.broadcast()
                return nil
            }
            busy += 1
            progress.currentPath = job.path
            return job
        }
    }

    /// Reads one folder in batches, checking for cancellation before each, then adds what it read to the tree. A
    /// folder that is no longer the one its entry described is not read.
    private func read(_ job: Job, buffer: UnsafeMutableRawBufferPointer) {
        var children: [(name: String, facts: EntryFacts)] = []
        var readError: Int32 = 0
        var partial = false
        var opened = Opened.expected
        let fd = Self.openDirectory(job.path)
        if fd < 0 {
            readError = -fd
        } else {
            defer { close(fd) }
            opened = job.identity.map { Self.check(fd, against: $0) } ?? .expected
            var list = BulkAttributes.list
            while opened == .expected {
                if isCancelled {
                    partial = true
                    break
                }
                let count = getattrlistbulk(fd, &list, buffer.baseAddress!, buffer.count, BulkAttributes.options)
                if count < 0 {
                    if errno == EINTR { continue }
                    readError = errno
                    break
                }
                if count == 0 { break }
                let batch = BulkAttributes.parse(UnsafeRawBufferPointer(buffer), count: Int(count)).map { entry in
                    // Inside a package every folder is read the same way, so Launch Services is not asked.
                    var facts = EntryFacts(entry) {
                        !job.inPackage && scanner.isPackage(Self.join(job.path, entry.name))
                    }
                    // A cancelled scan stops reading ranges too, between calls, so a batch of clones or one
                    // fragmented clone does not hold it up; a clone left unread is counted from its clone ID.
                    if facts.needsExtents, let id = entry.fileID {
                        facts.use(extents: PhysicalExtents.read(in: fd, name: entry.name, fileID: id,
                                                                allocated: facts.sizes.allocated,
                                                                isCancelled: { isCancelled }, map: scanner.mapExtent))
                    }
                    return (name: entry.name, facts: facts)
                }
                children.append(contentsOf: publish(batch))
            }
        }
        condition.withLock {
            defer {
                busy -= 1
                condition.broadcast()
            }
            if readError != 0 { builder.markUnreadable(job.node, path: job.path, isItem: job.isItem) }
            if partial { builder.insert(.partial, into: job.node) }
            switch opened {
            case .expected:
                break
            case .mounted:
                // Inside a package the folder's own allocation, counted when it was listed, stays.
                if job.isItem { builder.becameMountPoint(job.node) }
                return
            case .replaced:
                builder.insert(.incomplete, into: job.node)
                return
            }
            if job.inPackage {
                for child in children {
                    builder.addToPackage(child.facts, owner: job.node, path: Self.join(job.path, child.name))
                    if child.facts.descent != nil {
                        queue.append(Job(node: job.node, path: Self.join(job.path, child.name),
                                         identity: child.facts.opensAs, inPackage: true, isItem: false))
                    }
                }
                return
            }
            let nameBytes = children.reduce(0) { $0 + $1.name.utf8.count }
            guard builder.hasRoom(for: children.count, nameBytes: nameBytes) else {
                builder.insert(.partial, into: job.node)
                return
            }
            let first = builder.appendChildren(children, to: job.node, parentPath: job.path)
            for (offset, child) in children.enumerated() where child.facts.descent != nil {
                queue.append(Job(node: first + Int32(offset), path: Self.join(job.path, child.name),
                                 identity: child.facts.opensAs, inPackage: child.facts.descent == .package,
                                 isItem: true))
            }
        }
    }

    /// Admits a batch's folders to the tree, so one reached twice counts once, adds the batch to the progress, and
    /// reports it when due. Returns the batch as admitted.
    private func publish(_ batch: [(name: String, facts: EntryFacts)]) -> [(name: String, facts: EntryFacts)] {
        let (admitted, snapshot): ([(name: String, facts: EntryFacts)], DiskScanProgress?) = condition.withLock {
            let admitted = batch.map { (name: $0.name, facts: builder.admit($0.facts)) }
            progress.items += admitted.count
            for (_, facts) in admitted {
                if facts.descent != nil {
                    progress.allocatedBytes += facts.contribution.allocated
                } else if let link = facts.link {
                    if countedLinks.insert(link).inserted { progress.allocatedBytes += facts.sizes.allocated }
                } else {
                    progress.allocatedBytes += facts.sizes.allocated
                }
            }
            guard onProgress != nil else { return (admitted, nil) }
            let now = ContinuousClock.now
            if let lastPublished, now - lastPublished < scanner.progressInterval { return (admitted, nil) }
            lastPublished = now
            return (admitted, progress)
        }
        guard let snapshot else { return admitted }
        delivery.withLock {
            guard snapshot.items > deliveredItems else { return }
            deliveredItems = snapshot.items
            onProgress?(snapshot)
        }
        return admitted
    }

    /// What an opened folder is, against the entry it was queued from.
    enum Opened: Equatable {
        case expected
        /// Another volume was mounted on it after its parent was read.
        case mounted
        /// Another folder took its place on the same volume.
        case replaced
    }

    /// Compares an opened folder's volume and inode with those its entry reported. The volume is the file system's
    /// ID, which `ATTR_CMNEXT_REALDEVID` reports: `st_dev` gives the startup disk's system volume the data volume's.
    static func check(_ fd: Int32, against expected: FileKey) -> Opened {
        var info = stat()
        var volume = statfs()
        guard fstat(fd, &info) == 0, fstatfs(fd, &volume) == 0 else { return .replaced }
        // A volume that did not report its device (`0`) is checked by inode alone.
        if expected.device != 0, UInt32(bitPattern: volume.f_fsid.val.0) != expected.device { return .mounted }
        return UInt64(info.st_ino) == expected.id ? .expected : .replaced
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    /// Opens a folder without following a symbolic link anywhere in its path, or returns `-errno`. A path longer than
    /// `PATH_MAX` is opened one component at a time.
    static func openDirectory(_ path: String) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        let fd = open(path, flags)
        if fd >= 0 { return fd }
        guard errno == ENAMETOOLONG, path.hasPrefix("/") else { return -errno }
        var current = open("/", flags)
        guard current >= 0 else { return -errno }
        for component in path.split(separator: "/") {
            let next = openat(current, String(component), flags)
            let error = errno
            close(current)
            guard next >= 0 else { return -error }
            current = next
        }
        return current
    }
}
