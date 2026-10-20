import Darwin
import Foundation

/// How far a scan has got. Bytes are allocated bytes with each hard-linked file counted once; clones are resolved
/// only in the final totals.
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

    public init(workers: Int = DiskScanner.defaultWorkers, progressInterval: Duration = .milliseconds(100)) {
        self.init(workers: workers, progressInterval: progressInterval, bufferSize: 128 << 10,
                  isPackage: DiskScanner.launchServicesIsPackage)
    }

    init(workers: Int, progressInterval: Duration, bufferSize: Int, isPackage: @escaping @Sendable (String) -> Bool) {
        self.workers = max(1, workers)
        self.progressInterval = progressInterval
        self.bufferSize = bufferSize
        self.isPackage = isPackage
    }

    /// Scans `root`, calling `onProgress` from a worker thread at most once per `progressInterval`, one call at a time
    /// and with the item count always rising. Cancelling the calling task stops every worker at its next batch of
    /// entries and returns what was read.
    public func scan(_ root: URL = DiskScanner.defaultRoot,
                     onProgress: (@Sendable (DiskScanProgress) -> Void)? = nil) async throws(DiskScanError)
        -> DiskScanResult {
        let path = try Self.resolve(root.path)
        let scan = DiskScan(scanner: self, rootPath: path, onProgress: onProgress)
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
        /// Inside a package: entries add to `node`'s total and are not items.
        let inPackage: Bool
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
        _ = builder.visit(root.directory)
        self.builder = builder
        queue = root.descent.map { [Job(node: 0, path: rootPath, inPackage: $0 == .package)] } ?? []
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
            let thread = Thread { [self] in work() }
            thread.name = "Disk scan"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    private var isCancelled: Bool { condition.withLock { cancelled } }

    private func work() {
        // Reading a dataless file or folder must never download it.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
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

    /// Reads one folder in batches, checking for cancellation before each, then adds what it read to the tree.
    private func read(_ job: Job, buffer: UnsafeMutableRawBufferPointer) {
        var children: [(name: String, facts: EntryFacts)] = []
        var readError: Int32 = 0
        var partial = false
        let fd = Self.openDirectory(job.path)
        if fd < 0 {
            readError = -fd
        } else {
            defer { close(fd) }
            var list = BulkAttributes.list
            while true {
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
                    (name: entry.name, facts: EntryFacts(entry) { scanner.isPackage(Self.join(job.path, entry.name)) })
                }
                children.append(contentsOf: batch)
                publish(batch.map(\.facts))
            }
        }
        condition.withLock {
            defer {
                busy -= 1
                condition.broadcast()
            }
            if readError != 0 { builder.markUnreadable(job.node, path: job.path, isItem: !job.inPackage) }
            if partial { builder.insert(.partial, into: job.node) }
            if job.inPackage {
                for child in children {
                    builder.addToPackage(child.facts, owner: job.node, path: Self.join(job.path, child.name))
                    if child.facts.descent != nil, builder.visit(child.facts.directory) {
                        queue.append(Job(node: job.node, path: Self.join(job.path, child.name), inPackage: true))
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
                let node = first + Int32(offset)
                guard builder.visit(child.facts.directory) else {
                    builder.insert(.countedElsewhere, into: node)
                    continue
                }
                queue.append(Job(node: node, path: Self.join(job.path, child.name),
                                 inPackage: child.facts.descent == .package))
            }
        }
    }

    private func publish(_ batch: [EntryFacts]) {
        let snapshot: DiskScanProgress? = condition.withLock {
            progress.items += batch.count
            for facts in batch {
                if let link = facts.link {
                    if countedLinks.insert(link).inserted { progress.allocatedBytes += facts.sizes.allocated }
                } else {
                    progress.allocatedBytes += facts.sizes.allocated
                }
            }
            guard onProgress != nil else { return nil }
            let now = ContinuousClock.now
            if let lastPublished, now - lastPublished < scanner.progressInterval { return nil }
            lastPublished = now
            return progress
        }
        guard let snapshot else { return }
        delivery.withLock {
            guard snapshot.items > deliveredItems else { return }
            deliveredItems = snapshot.items
            onProgress?(snapshot)
        }
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
