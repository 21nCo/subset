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
/// The index is rebuilt when a plist, a plist folder, or an application folder changes size or modification time,
/// or appears or disappears. A plist without a label or program, or that does not parse, is listed in
/// `unreadablePlists` and left out.
public final class LaunchdJobIndex: LaunchdJobReading, @unchecked Sendable {
    /// launchd's default `PATH` for jobs.
    static let launchdPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private let folders: LaunchdFolders
    private let lock = NSLock()
    private var stamps: Set<FileStamp>?
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
        lock.withLock {
            guard scan.stamps != stamps else { return }
            stamps = scan.stamps
            state = Self.build(scan.plists)
        }
    }

    public func launchdJobs(forExecutable path: String?) -> Signal<[LaunchdJob]> {
        guard let path else { return .unavailable(.noExecutablePath, source: .launchdPlists) }
        let byProgram = lock.withLock { () -> [String: [LaunchdJob]] in
            if stamps == nil {
                let scan = Self.scan(folders)
                stamps = scan.stamps
                state = Self.build(scan.plists)
            }
            return state.byProgram
        }
        let jobs = byProgram[path] ?? Self.realPath(path).flatMap { byProgram[$0] } ?? []
        return .value(jobs, source: .launchdPlists)
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

    private static func build(_ plists: [(path: String, domain: LaunchdDomain, bundlePath: String?)])
        -> (jobs: [LaunchdJob], unreadable: [String], byProgram: [String: [LaunchdJob]]) {
        var jobs: [LaunchdJob] = []
        var unreadable: [String] = []
        for plist in plists {
            guard let job = job(at: plist.path, domain: plist.domain, bundlePath: plist.bundlePath) else {
                unreadable.append(plist.path)
                continue
            }
            jobs.append(job)
        }
        jobs.sort { $0.plistPath < $1.plistPath }
        var byProgram: [String: [LaunchdJob]] = [:]
        for job in jobs {
            if let program = job.resolvedProgram { byProgram[program, default: []].append(job) }
        }
        return (jobs, unreadable.sorted(), byProgram)
    }

    static func job(at plistPath: String, domain: LaunchdDomain, bundlePath: String?) -> LaunchdJob? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty
        else { return nil }
        let resolved: String?
        let program: String
        if let value = plist["Program"] as? String, !value.isEmpty {
            program = value
            resolved = resolve(value, workingDirectory: plist["WorkingDirectory"] as? String)
        } else if let bundlePath, let value = plist["BundleProgram"] as? String, !value.isEmpty {
            program = value
            resolved = realPath(bundlePath + "/" + value)
        } else if let value = (plist["ProgramArguments"] as? [Any])?.first as? String, !value.isEmpty {
            program = value
            resolved = resolve(value, workingDirectory: plist["WorkingDirectory"] as? String)
        } else {
            return nil
        }
        return LaunchdJob(label: label, plistPath: plistPath, domain: domain, program: program, resolvedProgram: resolved)
    }

    /// Resolves a program as `execvp` would for launchd, which starts jobs in `WorkingDirectory` or `/`.
    static func resolve(_ program: String, workingDirectory: String?) -> String? {
        if program.hasPrefix("/") { return realPath(program) }
        if program.contains("/") { return realPath((workingDirectory ?? "") + "/" + program) }
        return launchdPath.lazy.compactMap { realPath($0 + "/" + program) }.first
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
