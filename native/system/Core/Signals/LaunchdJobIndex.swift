import Darwin
import Foundation

/// The launchd jobs that run an executable.
public protocol LaunchdJobReading: Sendable {
    /// Rebuilds the index if a watched folder or plist changed since the last build. Called once per batch of reads.
    func refreshIfChanged()
    func launchdJobs(forExecutable path: String?) -> Signal<[LaunchdJob]>
}

/// The folders a `LaunchdJobIndex` reads.
public struct LaunchdFolders: Sendable {
    /// Folders of job plists.
    public var plistFolders: [(path: String, domain: LaunchdDomain)]
    /// Folders of installed apps, each `.app` in which, or in a subfolder up to two levels down, may embed agents in
    /// `Contents/Library/LaunchAgents`.
    public var applicationFolders: [String]

    public init(plistFolders: [(path: String, domain: LaunchdDomain)], applicationFolders: [String]) {
        self.plistFolders = plistFolders
        self.applicationFolders = applicationFolders
    }

    /// The folders a non-root user can read. Apple's own jobs in `/System/Library` are not indexed: their programs
    /// are platform binaries, which the code signature already identifies.
    public static func live(home: String = NSHomeDirectory()) -> LaunchdFolders {
        LaunchdFolders(
            plistFolders: [
                (home + "/Library/LaunchAgents", .userAgent),
                ("/Library/LaunchAgents", .globalAgent),
                ("/Library/LaunchDaemons", .globalDaemon)
            ],
            applicationFolders: ["/Applications", home + "/Applications"]
        )
    }
}

/// Maps each job's program to the job's label and plist. The program is `Program`, else `BundleProgram` (relative
/// to its app bundle, for agents embedded in one), else `ProgramArguments[0]`, which launchd resolves like
/// `execvp`: a name without a slash is searched for in launchd's default `PATH`. Symlinks are resolved, since the
/// kernel reports a running process by its real path (Homebrew services, for one, name a symlink). A plist whose
/// program does not exist is kept as `orphaned`.
///
/// The plists are read again when a plist, a plist folder, or an application folder changes size, modification
/// time, or status-change time (so a permission change counts), appears or disappears, or can or can no longer be
/// read. The programs are resolved again on every refresh, since an executable can be
/// created, deleted, or have its symlink retargeted (as `brew upgrade` does to `/opt/homebrew/opt`) while its plist
/// stays the same. A plist without a label or program, that does not parse, or that is not a regular file (a
/// folder, FIFO, or device named `.plist`, which is opened without blocking) is listed in `unreadablePlists` and
/// left out: launchd cannot load it either. A folder or plist that exists but cannot be read, such as one without
/// read permission, is listed in `scanFailures`, and an executable no readable plist names is then `unavailable`
/// rather than known to have no job, since launchd, running as root, may load a job from it. A missing folder is not
/// a failure.
public final class LaunchdJobIndex: LaunchdJobReading, @unchecked Sendable {
    /// launchd's default `PATH` for jobs.
    static let launchdPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private let folders: LaunchdFolders
    private let lock = NSLock()
    private var stamps: Set<FileStamp>?
    private var folderFailures: [LaunchdScanFailure] = []
    private var definitions: [Definition] = []
    private var plistFailures: [LaunchdScanFailure] = []
    private var state = (
        jobs: [LaunchdJob](), unreadable: [String](), failures: [LaunchdScanFailure](), byProgram: [String: [LaunchdJob]]()
    )

    public init(folders: LaunchdFolders = .live()) {
        self.folders = folders
    }

    /// Every indexed job, orphaned ones included, ordered by plist path.
    public var jobs: [LaunchdJob] { lock.withLock { state.jobs } }
    /// Plists that do not parse or lack a label or program; launchd cannot load them either.
    public var unreadablePlists: [String] { lock.withLock { state.unreadable } }
    /// Folders and plists that exist but could not be read, ordered by path.
    public var scanFailures: [LaunchdScanFailure] { lock.withLock { state.failures } }

    public func refreshIfChanged() {
        let scan = Self.scan(folders)
        lock.withLock { refresh(scan) }
    }

    public func launchdJobs(forExecutable path: String?) -> Signal<[LaunchdJob]> {
        guard let path else { return .unavailable(.noExecutablePath, source: .launchdPlists) }
        let (byProgram, failures) = lock.withLock {
            if stamps == nil { refresh(Self.scan(folders)) }
            return (state.byProgram, state.failures)
        }
        let jobs = byProgram[path] ?? Self.realPath(path).flatMap { byProgram[$0] } ?? []
        // A job that was found stands; the absence of one is known only when every plist was read.
        if jobs.isEmpty, !failures.isEmpty { return .unavailable(.incompleteScan(failures), source: .launchdPlists) }
        return .value(jobs, source: .launchdPlists)
    }

    /// Reads the plists again if the scan differs, then resolves every program. Call with the lock held.
    private func refresh(_ scan: Scan) {
        var unreadable = state.unreadable
        if scan.stamps != stamps || scan.failures != folderFailures {
            stamps = scan.stamps
            folderFailures = scan.failures
            (definitions, unreadable, plistFailures) = Self.read(scan.plists)
        }
        let jobs = definitions.map { $0.job() }
        let failures = (folderFailures + plistFailures).sorted { $0.path < $1.path }
        guard jobs != state.jobs || unreadable != state.unreadable || failures != state.failures else { return }
        var byProgram: [String: [LaunchdJob]] = [:]
        for job in jobs {
            if let program = job.resolvedProgram { byProgram[program, default: []].append(job) }
        }
        state = (jobs, unreadable, failures, byProgram)
    }

    private struct Scan {
        var stamps: Set<FileStamp> = []
        var plists: [(path: String, domain: LaunchdDomain, bundlePath: String?)] = []
        var failures: [LaunchdScanFailure] = []
    }

    /// Lists every plist and stamps every folder and plist it found, so any change shows as a different stamp set,
    /// and records each folder that exists but could not be listed.
    private static func scan(_ folders: LaunchdFolders) -> Scan {
        var scan = Scan()
        var plistFolders = folders.plistFolders.map { (path: $0.path, domain: $0.domain, bundlePath: String?.none) }
        for applications in folders.applicationFolders {
            for bundle in appBundles(in: applications, depth: appFolderDepth, scan: &scan) {
                plistFolders.append((bundle + "/Contents/Library/LaunchAgents", .appBundleAgent(bundlePath: bundle), bundle))
            }
        }
        for folder in plistFolders {
            for entry in list(folder.path, into: &scan) where entry.hasSuffix(".plist") {
                let path = folder.path + "/" + entry
                if let stamp = FileStamp(path: path) { scan.stamps.insert(stamp) }
                scan.plists.append((path, folder.domain, folder.bundlePath))
            }
        }
        return scan
    }

    /// How many folders deep below an application folder apps are looked for, so `/Applications/Utilities` and a
    /// vendor's folder are covered without walking the whole disk. A bundle's own contents are not searched.
    static let appFolderDepth = 2

    /// The `.app` bundles in `folder` and, up to `depth` levels down, in its subfolders, stamping each folder read.
    private static func appBundles(in folder: String, depth: Int, scan: inout Scan) -> [String] {
        var bundles: [String] = []
        for entry in list(folder, into: &scan) where !entry.hasPrefix(".") {
            let path = folder + "/" + entry
            if entry.hasSuffix(".app") {
                bundles.append(path)
            } else if depth > 0, isFolder(path) {
                bundles += appBundles(in: path, depth: depth - 1, scan: &scan)
            }
        }
        return bundles
    }

    /// A real folder, not a symlink to one, so a link cannot lead the scan elsewhere on the disk.
    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Stamps a folder and returns its entries, sorted. A missing folder has none; one that exists but cannot be
    /// listed has none and is recorded in `scan.failures`.
    private static func list(_ folder: String, into scan: inout Scan) -> [String] {
        var info = stat()
        guard stat(folder, &info) == 0 else {
            let code = errno
            if !isMissing(code) { scan.failures.append(LaunchdScanFailure(path: folder, code: code)) }
            return []
        }
        scan.stamps.insert(FileStamp(path: folder, info: info))
        guard let directory = opendir(folder) else {
            let code = errno
            if !isMissing(code) { scan.failures.append(LaunchdScanFailure(path: folder, code: code)) }
            return []
        }
        defer { closedir(directory) }
        var entries: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { scan.failures.append(LaunchdScanFailure(path: folder, code: errno)) }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if name != ".", name != ".." { entries.append(name) }
        }
        return entries.sorted()
    }

    /// Nothing is there, as opposed to something that cannot be read.
    private static func isMissing(_ code: Int32) -> Bool { code == ENOENT || code == ENOTDIR }

    /// Parses the plists, ordered by path, and lists the ones that do not parse and the ones that cannot be read.
    private static func read(_ plists: [(path: String, domain: LaunchdDomain, bundlePath: String?)])
        -> (definitions: [Definition], unreadable: [String], failures: [LaunchdScanFailure]) {
        var definitions: [Definition] = []
        var unreadable: [String] = []
        var failures: [LaunchdScanFailure] = []
        for plist in plists {
            let data: Data
            switch contents(of: plist.path) {
            case let .success(contents): data = contents
            case let .failure(error):
                // A plist removed since the folder was listed is simply gone.
                if !isMissing(error.code) { failures.append(LaunchdScanFailure(path: plist.path, code: error.code)) }
                continue
            }
            guard let definition = Definition(plistPath: plist.path, data: data, domain: plist.domain,
                                              bundlePath: plist.bundlePath) else {
                unreadable.append(plist.path)
                continue
            }
            definitions.append(definition)
        }
        definitions.sort { $0.plistPath < $1.plistPath }
        return (definitions, unreadable.sorted(), failures)
    }

    private struct ReadError: Error {
        let code: Int32
    }

    private static func contents(of path: String) -> Result<Data, ReadError> {
        // Opened without blocking, so a FIFO or device named `.plist` (the user's agents folder is writable) cannot
        // stall the scan, and checked by its descriptor, so an entry replaced since it was listed is caught too.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(ReadError(code: errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // Something other than a file, such as a folder, FIFO, or device named `.plist`, or a symlink to one, is no
        // plist: it is read as empty, which does not parse.
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .success(Data()) }
        do {
            return .success(try handle.readToEnd() ?? Data())
        } catch {
            return .failure(ReadError(code: EIO))
        }
    }

    /// One parsed plist, with its program not yet resolved.
    struct Definition: Sendable {
        let label: String
        let plistPath: String
        let domain: LaunchdDomain
        /// As the plist writes it.
        let program: String
        /// Where launchd finds the program: this path, or, for a name without a slash, launchd's `PATH`.
        let location: String?

        init?(plistPath: String, data: Data, domain: LaunchdDomain, bundlePath: String?) {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String, !label.isEmpty
            else { return nil }
            let workingDirectory = plist["WorkingDirectory"] as? String
            if let value = plist["Program"] as? String, !value.isEmpty {
                program = value
                location = LaunchdJobIndex.location(of: value, workingDirectory: workingDirectory)
            } else if let bundlePath, let value = plist["BundleProgram"] as? String, !value.isEmpty {
                program = value
                location = bundlePath + "/" + value
            } else if let value = (plist["ProgramArguments"] as? [Any])?.first as? String, !value.isEmpty {
                program = value
                location = LaunchdJobIndex.location(of: value, workingDirectory: workingDirectory)
            } else {
                return nil
            }
            self.label = label
            self.plistPath = plistPath
            self.domain = domain
        }

        /// The job with its program resolved as the filesystem stands now.
        func job() -> LaunchdJob {
            let resolved = if let location {
                LaunchdJobIndex.realPath(location)
            } else {
                LaunchdJobIndex.launchdPath.lazy.compactMap { LaunchdJobIndex.realPath($0 + "/" + program) }.first
            }
            return LaunchdJob(label: label, plistPath: plistPath, domain: domain, program: program, resolvedProgram: resolved)
        }
    }

    /// Where `execvp` looks for a program for launchd, which starts jobs in `WorkingDirectory` or `/`: the path
    /// itself, or `nil` for a bare name, which is searched for in `launchdPath`.
    static func location(of program: String, workingDirectory: String?) -> String? {
        if program.hasPrefix("/") { return program }
        if program.contains("/") { return (workingDirectory ?? "") + "/" + program }
        return nil
    }

    /// The path with symlinks resolved, or `nil` when no regular file is there.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return String(cString: resolved)
    }
}
