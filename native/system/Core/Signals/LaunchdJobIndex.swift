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
    /// Folders of installed apps, each `.app` in which may embed agents in `Contents/Library/LaunchAgents`.
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
/// The plists are read again when a plist, a plist folder, or an application folder changes size or modification
/// time, or appears or disappears. The programs are resolved again on every refresh, since an executable can be
/// created, deleted, or have its symlink retargeted (as `brew upgrade` does to `/opt/homebrew/opt`) while its plist
/// stays the same. A plist without a label or program, or that does not parse, is listed in `unreadablePlists` and
/// left out.
public final class LaunchdJobIndex: LaunchdJobReading, @unchecked Sendable {
    /// launchd's default `PATH` for jobs.
    static let launchdPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private let folders: LaunchdFolders
    private let lock = NSLock()
    private var stamps: Set<FileStamp>?
    private var definitions: [Definition] = []
    private var state = (jobs: [LaunchdJob](), unreadable: [String](), byProgram: [String: [LaunchdJob]]())

    public init(folders: LaunchdFolders = .live()) {
        self.folders = folders
    }

    /// Every indexed job, orphaned ones included, ordered by plist path.
    public var jobs: [LaunchdJob] { lock.withLock { state.jobs } }
    /// Plists that could not be read or lack a label or program.
    public var unreadablePlists: [String] { lock.withLock { state.unreadable } }

    public func refreshIfChanged() {
        let scan = Self.scan(folders)
        lock.withLock { refresh(scan) }
    }

    public func launchdJobs(forExecutable path: String?) -> Signal<[LaunchdJob]> {
        guard let path else { return .unavailable(.noExecutablePath, source: .launchdPlists) }
        let byProgram = lock.withLock { () -> [String: [LaunchdJob]] in
            if stamps == nil { refresh(Self.scan(folders)) }
            return state.byProgram
        }
        let jobs = byProgram[path] ?? Self.realPath(path).flatMap { byProgram[$0] } ?? []
        return .value(jobs, source: .launchdPlists)
    }

    /// Reads the plists again if the scan differs, then resolves every program. Call with the lock held.
    private func refresh(_ scan: Scan) {
        var unreadable = state.unreadable
        if scan.stamps != stamps {
            stamps = scan.stamps
            (definitions, unreadable) = Self.read(scan.plists)
        }
        let jobs = definitions.map { $0.job() }
        guard jobs != state.jobs || unreadable != state.unreadable else { return }
        var byProgram: [String: [LaunchdJob]] = [:]
        for job in jobs {
            if let program = job.resolvedProgram { byProgram[program, default: []].append(job) }
        }
        state = (jobs, unreadable, byProgram)
    }

    private struct Scan {
        var stamps: Set<FileStamp> = []
        var plists: [(path: String, domain: LaunchdDomain, bundlePath: String?)] = []
    }

    /// Lists every plist and stamps every folder and plist it found, so any change shows as a different stamp set.
    private static func scan(_ folders: LaunchdFolders) -> Scan {
        var scan = Scan()
        var plistFolders = folders.plistFolders.map { (path: $0.path, domain: $0.domain, bundlePath: String?.none) }
        for applications in folders.applicationFolders {
            guard let stamp = FileStamp(path: applications) else { continue }
            scan.stamps.insert(stamp)
            for entry in contents(of: applications) where entry.hasSuffix(".app") {
                let bundle = applications + "/" + entry
                plistFolders.append((bundle + "/Contents/Library/LaunchAgents", .appBundleAgent(bundlePath: bundle), bundle))
            }
        }
        for folder in plistFolders {
            guard let stamp = FileStamp(path: folder.path) else { continue }
            scan.stamps.insert(stamp)
            for entry in contents(of: folder.path).sorted() where entry.hasSuffix(".plist") {
                let path = folder.path + "/" + entry
                if let stamp = FileStamp(path: path) { scan.stamps.insert(stamp) }
                scan.plists.append((path, folder.domain, folder.bundlePath))
            }
        }
        return scan
    }

    private static func contents(of folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }

    /// Parses the plists, ordered by path, and lists the unreadable ones.
    private static func read(_ plists: [(path: String, domain: LaunchdDomain, bundlePath: String?)])
        -> (definitions: [Definition], unreadable: [String]) {
        var definitions: [Definition] = []
        var unreadable: [String] = []
        for plist in plists {
            guard let definition = Definition(plistPath: plist.path, domain: plist.domain, bundlePath: plist.bundlePath) else {
                unreadable.append(plist.path)
                continue
            }
            definitions.append(definition)
        }
        definitions.sort { $0.plistPath < $1.plistPath }
        return (definitions, unreadable.sorted())
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

        init?(plistPath: String, domain: LaunchdDomain, bundlePath: String?) {
            guard let data = FileManager.default.contents(atPath: plistPath),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
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
