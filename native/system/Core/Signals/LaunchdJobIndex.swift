import Darwin
import Foundation

/// The launchd jobs that run an executable.
public protocol LaunchdJobReading: Sendable {
    /// Rebuilds the index if a watched folder or plist changed since the last build. Called once per sample.
    /// Returns whether the jobs, unreadable plists, or scan failures changed, so answers given before may be stale.
    @discardableResult func refreshIfChanged() -> Bool
    /// The jobs the readable plists give the executable, with the scan's failures; `unavailable(.incompleteScan)`
    /// when no readable plist names it and the scan had failures.
    func launchdJobs(forExecutable path: String?) -> Signal<LaunchdJobs>
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

/// Maps each job's program to the job's label and plist. The program is `Program`, which must be absolute, else
/// `BundleProgram` (relative to its app bundle, for agents embedded in one), else `ProgramArguments[0]`, which
/// launchd resolves like `execvp`: a name without a slash is searched for in launchd's default `PATH`. Symlinks are resolved, since the
/// kernel reports a running process by its real path (Homebrew services, for one, name a symlink). A plist whose
/// program does not exist is kept as `orphaned`; one whose path cannot be checked, such as a program in a folder
/// without search permission, is `unchecked`, not orphaned.
///
/// The plists are read again when a plist, a plist folder, or an application folder changes size, modification
/// time, or status-change time (so a permission change counts), appears or disappears, or can or can no longer be
/// read. The programs are resolved again on every refresh, since an executable can be
/// created, deleted, or have its symlink retargeted (as `brew upgrade` does to `/opt/homebrew/opt`) while its plist
/// stays the same. A plist without a label or program, with a relative `Program`, that does not parse, or that is not a regular file (a
/// folder, FIFO, or device named `.plist`, which is opened without blocking) is listed in `unreadablePlists` and
/// left out: launchd cannot load it either. A folder or plist that exists but cannot be read, such as one without
/// read permission or a plist larger than `maximumPlistSize`, is listed in `scanFailures`, as is an unchecked
/// program, since launchd, running as root, may load a job from it or find the program there: the jobs found for an
/// executable then carry the failures, and an executable no readable plist names is `unavailable` rather than known
/// to have no job. A missing folder is not a failure.
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
    /// Plists that do not parse, lack a label or program, or have a relative `Program`; launchd cannot load them
    /// either.
    public var unreadablePlists: [String] { lock.withLock { state.unreadable } }
    /// Folders and plists that exist but could not be read, and programs that could not be checked, ordered by path.
    public var scanFailures: [LaunchdScanFailure] { lock.withLock { state.failures } }

    @discardableResult public func refreshIfChanged() -> Bool {
        let scan = Self.scan(folders)
        return lock.withLock { refresh(scan) }
    }

    public func launchdJobs(forExecutable path: String?) -> Signal<LaunchdJobs> {
        guard let path else { return .unavailable(.noExecutablePath, source: .launchdPlists) }
        let (byProgram, failures) = lock.withLock {
            if stamps == nil { _ = refresh(Self.scan(folders)) }
            return (state.byProgram, state.failures)
        }
        let jobs = byProgram[path] ?? Self.realPath(path).flatMap { byProgram[$0] } ?? []
        // A job that was found stands, but is not known to be the only one, and the absence of one is known only
        // when every plist was read.
        if jobs.isEmpty, !failures.isEmpty { return .unavailable(.incompleteScan(failures), source: .launchdPlists) }
        return .value(LaunchdJobs(jobs: jobs, scanFailures: failures), source: .launchdPlists)
    }

    /// Reads the plists again if the scan differs, then resolves every program, and tells whether the index
    /// changed. Call with the lock held.
    private func refresh(_ scan: Scan) -> Bool {
        var unreadable = state.unreadable
        if scan.stamps != stamps || scan.failures != folderFailures {
            stamps = scan.stamps
            folderFailures = scan.failures
            (definitions, unreadable, plistFailures) = Self.read(scan.plists)
        }
        let jobs = definitions.map { $0.job() }
        let programFailures = jobs.compactMap { job in
            if case let .unchecked(failure) = job.resolution { failure } else { nil }
        }
        let failures = Set(folderFailures + plistFailures + programFailures).sorted { ($0.path, $0.code) < ($1.path, $1.code) }
        guard jobs != state.jobs || unreadable != state.unreadable || failures != state.failures else { return false }
        var byProgram: [String: [LaunchdJob]] = [:]
        for job in jobs {
            if let program = job.resolvedProgram { byProgram[program, default: []].append(job) }
        }
        state = (jobs, unreadable, failures, byProgram)
        return true
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
        // A plist larger than any job definition (the user's agents folder is writable) is not read into memory,
        // even if it grows while it is read; launchd may still load it, so it is a failure, not an unreadable plist.
        guard info.st_size <= maximumPlistSize else { return .failure(ReadError(code: EFBIG)) }
        do {
            let data = try handle.read(upToCount: maximumPlistSize + 1) ?? Data()
            return data.count > maximumPlistSize ? .failure(ReadError(code: EFBIG)) : .success(data)
        } catch {
            return .failure(ReadError(code: EIO))
        }
    }

    /// The largest plist read, in bytes; job definitions are a few kilobytes.
    static let maximumPlistSize = 1 << 20

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
                // launchd requires an absolute `Program`; only `ProgramArguments[0]` is looked up like `execvp`.
                guard value.hasPrefix("/") else { return nil }
                program = value
                location = value
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

        /// The job with its program resolved as the filesystem stands now. Like `execvp`, a bare name is the first
        /// entry of `launchdPath` that has it; it is unchecked only when none has it and one could not be checked.
        func job(searchPath: [String] = LaunchdJobIndex.launchdPath) -> LaunchdJob {
            let resolution: LaunchdProgramResolution
            if let location {
                resolution = LaunchdJobIndex.resolve(location)
            } else {
                let candidates = searchPath.map { LaunchdJobIndex.resolve($0 + "/" + program) }
                resolution = candidates.first { if case .resolved = $0 { true } else { false } }
                    ?? candidates.first { $0 != .missing } ?? .missing
            }
            return LaunchdJob(label: label, plistPath: plistPath, domain: domain, program: program, resolution: resolution)
        }
    }

    /// Where `execvp` looks for a program for launchd, which starts jobs in `WorkingDirectory` or `/`: the path
    /// itself, or `nil` for a bare name, which is searched for in `launchdPath`.
    static func location(of program: String, workingDirectory: String?) -> String? {
        if program.hasPrefix("/") { return program }
        if program.contains("/") { return (workingDirectory ?? "") + "/" + program }
        return nil
    }

    /// The path with symlinks resolved, or `nil` when no regular file is there or it could not be checked.
    static func realPath(_ path: String) -> String? {
        if case let .resolved(resolved) = resolve(path) { resolved } else { nil }
    }

    /// The regular file at the path, with symlinks resolved; `missing` when nothing, or something other than a
    /// regular file, is there; `unchecked` with the `errno` when the path could not be followed for another reason,
    /// such as a folder on it without search permission.
    static func resolve(_ path: String) -> LaunchdProgramResolution {
        func failed(_ code: Int32) -> LaunchdProgramResolution {
            code == ENOENT || code == ENOTDIR || code == ELOOP ? .missing : .unchecked(LaunchdScanFailure(path: path, code: code))
        }
        guard let resolved = realpath(path, nil) else { return failed(errno) }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0 else { return failed(errno) }
        return info.st_mode & S_IFMT == S_IFREG ? .resolved(String(cString: resolved)) : .missing
    }
}
