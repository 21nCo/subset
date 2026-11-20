import AppKit
import Darwin
import Foundation

/// Moves an app to the Trash; `SystemTrash` uses the user's Trash, tests a folder.
public protocol Trashing: Sendable {
    /// Moves `bundle` to the Trash and returns where it is there. Never deletes it. Any error means it was not moved; the
    /// installer then puts the copy back or says where it is, whatever the error's type.
    func trash(_ bundle: URL, appName: String, at date: Date) throws -> Trashed
}

/// Where a moved copy is in the Trash, and why it still has its hidden name there when it could not be renamed.
public struct Trashed: Sendable {
    public var url: URL
    public var renameFailure: String?

    /// `renameFailure`: why a copy that reached the Trash kept its hidden name there, or nil when it did not.
    public init(url: URL, renameFailure: String? = nil) {
        self.url = url
        self.renameFailure = renameFailure
    }

    /// What to tell the user when the copy kept its hidden name (Finder does not show it), or nil.
    var hiddenNote: String? {
        renameFailure.map { "It is in the Trash under the hidden name \(url.path) because it could not be renamed there (\($0)); in Finder, press Command-Shift-Period to see it." }
    }
}

/// The user's Trash, through FileManager.trashItem (the Trash of the bundle's volume). A copy set aside under a hidden
/// name is renamed in the Trash to `<appName> <date> <time>.app`, as the `subset` command names it, so it can be seen.
public struct SystemTrash: Trashing {
    public init() {}

    public func trash(_ bundle: URL, appName: String, at date: Date) throws -> Trashed {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: bundle, resultingItemURL: &result)
        } catch {
            throw InstallFailure(.trash, "\(bundle.path) cannot be moved to the Trash (\(error.localizedDescription))")
        }
        guard let trashed = result as URL? else { throw InstallFailure(.trash, "the Trash did not say where \(bundle.path) went") }
        return Self.name(trashed, appName: appName, at: date)
    }

    /// Renames a copy that reached the Trash under its hidden name; the move is done, so a failure is only reported.
    static func name(_ trashed: URL, appName: String, at date: Date) -> Trashed {
        guard trashed.lastPathComponent.hasPrefix(".") else { return Trashed(url: trashed) }
        do {
            return Trashed(url: try FolderTrash.renameInto(trashed.deletingLastPathComponent(), trashed, appName: appName, at: date))
        } catch {
            return Trashed(url: trashed, renameFailure: (error as? InstallFailure)?.message ?? error.localizedDescription)
        }
    }
}

/// A folder standing in for the Trash (tests and the CI install check): the bundle is renamed into it as
/// `<appName> <date> <time>.app`, never over anything already there.
public struct FolderTrash: Trashing {
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func trash(_ bundle: URL, appName: String, at date: Date) throws -> Trashed {
        Trashed(url: try Self.renameInto(folder, bundle, appName: appName, at: date))
    }

    static func renameInto(_ folder: URL, _ bundle: URL, appName: String, at date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: date)
        for n in 1...100 {
            let candidate = folder.appendingPathComponent("\(appName) \(stamp)\(n > 1 ? " \(n)" : "").app")
            if renamex_np(bundle.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            if errno != EEXIST { throw InstallFailure(.trash, "\(bundle.path) cannot be moved to the Trash \(folder.path) (\(String(cString: strerror(errno))))") }
        }
        throw InstallFailure(.trash, "the Trash \(folder.path) already holds 100 copies named \(appName) \(stamp).app")
    }
}

/// Finds and quits the processes of an installed copy; `WorkspaceRunningApps` asks the system, tests a stand-in.
public protocol RunningAppControlling: Sendable {
    /// The pids of the processes whose executable is inside `bundle` (its helpers too). Throws when the list of running
    /// processes, or the executable of one that still runs, cannot be read, so a running app is never taken for one that
    /// is not.
    func processes(inside bundle: URL) throws -> [pid_t]
    /// Asks each running app at `bundle` to quit (NSRunningApplication.terminate(), never a force quit), then waits up
    /// to `timeout` seconds for every process inside it to exit. Returns the pids still running and whether an app was
    /// asked to quit; when none was (only helpers run), it returns at once with the processes running then. A cancel
    /// asks no further app and waits only for those asked. `isChecked` says whether `bundle` is still the copy the caller
    /// checked; asked just before any app is, it refuses when it is not. Throws only when no app was asked.
    func quit(_ bundle: URL, timeout: TimeInterval, isChecked: @escaping @Sendable () -> Bool) async throws -> (left: [pid_t], asked: Bool)
}

/// The processes from libproc (each pid's executable path), quit with NSRunningApplication.terminate().
public struct WorkspaceRunningApps: RunningAppControlling {
    public init() {}

    /// Every process whose executable is inside `bundle`, this one included: a copy holding this app is running too.
    /// Paths are compared by BundleMatcher (real paths, case folded on a case-insensitive volume). A process is the
    /// copy's when libproc's path of its executable, or the path it was started with (KERN_PROCARGS2, which `ps` shows
    /// the `subset` command), is inside it. The start path stays when the executable, or a folder above it, was deleted,
    /// moved or replaced by a link since (libproc then names where the file is now, or nothing), so it is judged as saved
    /// and with each of its leading folders resolved now (BundleMatcher.startedInside). One of this user's that still
    /// runs and cannot be named either way refuses; one that has exited or is another user's (which `ps` cannot name
    /// either, and Subset cannot ask to quit) does not, told apart by the kernel's process record, which `ps` reads too
    /// (PROC_PIDTBSDINFO refuses another user's process with EPERM).
    public func processes(inside bundle: URL) throws -> [pid_t] {
        try Self.processes(inside: bundle, among: Self.allPids(), look: Self.look)
    }

    /// What is known of a process: the path of its executable, or why there is none.
    enum ProcessLook: Equatable {
        /// libproc's path of its executable now, and the path it was started with when that can be read.
        case path(String, started: String? = nil)
        /// The path it was started with, as saved (libproc cannot name it).
        case started(String)
        case exited
        case otherUser
        case unknown(Int32)
    }

    /// Those of `pids` whose executable is inside `bundle`, as `look` names them.
    static func processes(inside bundle: URL, among pids: [pid_t], look: (pid_t) -> ProcessLook) throws -> [pid_t] {
        let matcher = BundleMatcher(bundle)
        var resolved: [String: String?] = [:]
        return try pids.filter { pid in
            guard pid > 0 else { return false }
            switch look(pid) {
            // libproc names where the file is now: its start path adds something only when it differs, and then only as
            // saved (a link resolved now into the bundle does not make a process outside it the copy's).
            case let .path(path, started):
                if matcher.contains(path) { return true }
                guard let started, started != path else { return false }
                return matcher.startedInside(started, resolved: &resolved, linksIntoBundle: false)
            case let .started(path): return matcher.startedInside(path, resolved: &resolved, linksIntoBundle: true)
            case .exited, .otherUser: return false
            case let .unknown(code):
                throw InstallFailure(.running, "whether the app is running cannot be read (the executable of pid \(pid): \(String(cString: strerror(code))))")
            }
        }
    }

    static func look(_ pid: pid_t) -> ProcessLook {
        if let path = executable(of: pid) { return .path(path, started: startPath(of: pid).flatMap { $0.hasPrefix("/") ? $0 : nil }) }
        let code = errno
        if let path = startPath(of: pid), path.hasPrefix("/") { return .started(path) }
        let (record, failure) = record(of: pid)
        guard failure == 0 else { return .unknown(failure) }
        // No record: it has exited. SZOMB (5): exited, not yet reaped.
        guard let record, record.kp_proc.p_stat != 5 else { return .exited }
        let uid = getuid()
        return record.kp_eproc.e_ucred.cr_uid == uid || record.kp_eproc.e_pcred.p_ruid == uid ? .unknown(code) : .otherUser
    }

    /// The kernel's record of process `pid` (kinfo_proc), given for every user's process: nil when there is none, and the
    /// errno when it cannot be read.
    static func record(of pid: pid_t) -> (record: kinfo_proc?, failure: Int32) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return (nil, errno) }
        return (size == 0 ? nil : info, 0)
    }

    /// When process `pid` started, in microseconds, or nil when there is no such process: a pid given to another process
    /// since has another start time.
    static func startTime(of pid: pid_t) -> UInt64? {
        guard let record = record(of: pid).record else { return nil }
        let started = record.kp_proc.p_un.__p_starttime
        return UInt64(started.tv_sec) * 1_000_000 + UInt64(started.tv_usec)
    }

    /// The path process `pid` was started with (the exec path at the head of KERN_PROCARGS2), or nil when it cannot be read.
    static func startPath(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let text = buffer[MemoryLayout<Int32>.size..<size]
        return String(decoding: text.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The executable of this process (libproc, else the main bundle's), or nil when neither can be read.
    public static func ownExecutable() -> String? {
        executable(of: getpid()) ?? Bundle.main.executablePath
    }

    static func executable(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Every pid, from a buffer sized by asking libproc first; a list that fills the buffer may be cut short, so it is
    /// read again in a larger one. Throws when libproc fails (as update.mjs refuses when ps fails).
    static func allPids(list: (UnsafeMutableRawPointer?, Int32) -> Int32 = { proc_listallpids($0, $1) }) throws -> [pid_t] {
        let unreadable = { (why: String) in InstallFailure(.running, "whether the app is running cannot be read (\(why))") }
        var capacity = Int(list(nil, 0))
        guard capacity > 0 else { throw unreadable(String(cString: strerror(errno))) }
        for _ in 0..<4 {
            capacity += capacity / 4 + 64
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = Int(pids.withUnsafeMutableBytes { list($0.baseAddress, Int32($0.count)) })
            guard count > 0 else { throw unreadable(String(cString: strerror(errno))) }
            if count < capacity { return Array(pids.prefix(count)) }
        }
        throw unreadable("the list of processes kept growing")
    }

    public func quit(_ bundle: URL, timeout: TimeInterval, isChecked: @escaping @Sendable () -> Bool) async throws -> (left: [pid_t], asked: Bool) {
        // Each process of the copy, by when it started too.
        let mine = try processes(inside: bundle)
        let found = Dictionary(mine.map { ($0, Self.startTime(of: $0)) }, uniquingKeysWith: { first, _ in first })
        let matcher = BundleMatcher(bundle)
        let asked = try await MainActor.run { () throws -> [pid_t] in
            guard isChecked() else {
                throw InstallFailure(.running, "\(bundle.path) was replaced while it was being quit, so nothing was asked to quit")
            }
            let apps = Self.targets(NSWorkspace.shared.runningApplications, found: found, matcher: matcher, own: getpid(), startTime: Self.startTime) {
                ($0.processIdentifier, [$0.executableURL, $0.bundleURL])
            }
            return Self.ask(apps) { !$0.isTerminated && $0.terminate() }.map(\.processIdentifier)
        }
        guard !asked.isEmpty else {
            try Task.checkCancellation()
            // No app to ask: what runs now (the app may have exited meanwhile) is left, read again.
            return (try processes(inside: bundle), false)
        }
        let until = Date().addingTimeInterval(timeout)
        while true {
            // Once apps were asked, an unreadable list counts as still running, so this no longer throws.
            let left = (try? processes(inside: bundle)) ?? Array(mine)
            // After a cancel only the apps already asked are waited for.
            if left.isEmpty || Date() >= until || (Task.isCancelled && Set(left).isDisjoint(with: asked)) { return (left, true) }
            await ToolRunner.pause(nanoseconds: 200_000_000)
        }
    }

    /// The running apps to ask to quit: each that is a process `found` inside the bundle (the same pid, started at the
    /// same time) and whose executable or bundle, as the system reports it now, is that bundle's too, so a pid given to
    /// another process since is never asked. This app is never asked to quit itself (the installer refuses such a copy
    /// first); it stays in what is left.
    static func targets<App>(
        _ apps: [App], found: [pid_t: UInt64?], matcher: BundleMatcher, own: pid_t, startTime: (pid_t) -> UInt64?,
        _ identity: (App) -> (pid_t, [URL?])
    ) -> [App] {
        apps.filter { app in
            let (pid, urls) = identity(app)
            guard pid != own, case let started?? = found[pid], startTime(pid) == started else { return false }
            return urls.contains { $0.map { matcher.contains($0.path + "/") } ?? false }
        }
    }

    /// Asks each of `apps` to quit with `terminate` until the task is cancelled; returns those the request reached
    /// (terminate() is false for an app that had already exited).
    static func ask<App>(_ apps: [App], _ terminate: (App) -> Bool) -> [App] {
        var asked: [App] = []
        for app in apps {
            if Task.isCancelled { break }
            if terminate(app) { asked.append(app) }
        }
        return asked
    }
}

/// Whether a process's path is inside a bundle, matched as given and in its canonical form (every link resolved, so
/// libproc's /private/var matches /var), with case folded when the bundle's volume ignores case.
struct BundleMatcher: Sendable {
    let bundle: URL
    let foldsCase: Bool
    private let roots: [String]

    init(_ bundle: URL) {
        self.bundle = bundle
        let caseSensitive = try? bundle.deletingLastPathComponent().resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        let folds = caseSensitive == false
        foldsCase = folds
        roots = Set([bundle.path, bundle.resolvingSymlinksInPath().path, Self.canonical(bundle.path)]).map { (folds ? $0.lowercased() : $0) + "/" }
    }

    /// Whether `path` (a canonical one, as libproc and `look` give) is inside the bundle.
    func contains(_ path: String) -> Bool {
        let path = foldsCase ? path.lowercased() : path
        return roots.contains { path.hasPrefix($0) }
    }

    /// Whether a process started with `path` (absolute, as saved) may run from inside the bundle: as saved, and with its
    /// first 1, 2, ... folders resolved as they are now and the rest as saved, so a folder of the bundle that became a
    /// link elsewhere since (or was moved) does not hide it, even on a path that leaves the bundle and enters it again.
    /// A `..` after a link outside the bundle is not judged as saved (the kernel resolved it after the link), only in a
    /// resolved prefix. With `linksIntoBundle` false (libproc names the file outside the bundle), a prefix whose link
    /// resolves now into the bundle does not count, nor does the path fully resolved; with it (nothing names the file
    /// now) both do. `resolved` keeps the real paths already read (nil when a path does not exist).
    /// Not claimed (SET-252): a process another program started through an alias outside the bundle that leads into it,
    /// whose executable has moved since, is named by neither path.
    func startedInside(_ path: String, resolved: inout [String: String?], linksIntoBundle: Bool) -> Bool {
        let parts = path.split(separator: "/")
        if let saved = confined([], parts[...]), contains(saved) { return true }
        if linksIntoBundle, contains(Self.canonical(path)) { return true }
        for count in 1..<max(parts.count, 1) {
            let prefix = "/" + parts.prefix(count).joined(separator: "/")
            if resolved[prefix] == nil { resolved[prefix] = .some(AppInstaller.realPath(prefix)) }
            guard let real = resolved[prefix] ?? nil, linksIntoBundle || !contains(real + "/") else { continue }
            let head = real.split(separator: "/")
            if let saved = confined(head, parts[count...]), contains(saved) { return true }
        }
        return false
    }

    /// `head` followed by `rest` as saved, with `.` and repeated slashes removed and each `..` taken as leaving its
    /// folder: one inside the bundle (which may have been a folder when it started, whatever it is now) or one outside
    /// it that is not a link now; nil when a `..` would leave a link outside the bundle (taken as it resolves instead).
    private func confined(_ head: [Substring], _ rest: ArraySlice<Substring>) -> String? {
        var result = head
        for part in rest {
            switch part {
            case ".": continue
            case "..":
                guard !result.isEmpty else { continue }
                let folder = "/" + result.joined(separator: "/")
                var status = stat()
                let isLink = lstat(folder, &status) == 0 && status.st_mode & S_IFMT == S_IFLNK
                guard contains(folder) || !isLink else { return nil }
                result.removeLast()
            default: result.append(part)
            }
        }
        return "/" + result.joined(separator: "/")
    }

    /// `path` (absolute) with every link resolved as far as it exists, and `.`, `..` and repeated slashes removed.
    static func canonical(_ path: String) -> String {
        let parts = path.split(separator: "/")
        for count in stride(from: parts.count, through: 0, by: -1) {
            guard let real = AppInstaller.realPath("/" + parts.prefix(count).joined(separator: "/")) else { continue }
            return lexical(([Substring(real)] + parts.dropFirst(count)).joined(separator: "/"))
        }
        return lexical(path)
    }

    /// `path` (absolute) with `.`, `..` and repeated slashes removed, no link followed (for what does not exist).
    static func lexical(_ path: String) -> String {
        var result: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = result.popLast()
            default: result.append(part)
            }
        }
        return "/" + result.joined(separator: "/")
    }
}
