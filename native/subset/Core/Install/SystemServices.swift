import AppKit
import Darwin
import Foundation

/// Moves an app to the Trash; `SystemTrash` uses the user's Trash, tests a folder.
public protocol Trashing: Sendable {
    /// Moves `bundle` to the Trash and returns where it is there. Never deletes it.
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
    /// asks no further app and waits only for those asked. Throws only when no app was asked.
    func quit(_ bundle: URL, timeout: TimeInterval) async throws -> (left: [pid_t], asked: Bool)
    /// Opens the app at `bundle` again after it was quit for an update; returns why it could not, or nil.
    func reopen(_ bundle: URL) async -> String?
}

/// The processes from libproc (each pid's executable path), quit with NSRunningApplication.terminate().
public struct WorkspaceRunningApps: RunningAppControlling {
    public init() {}

    /// Every process whose executable is inside `bundle`, this one included: a copy holding this app is running too.
    /// Paths are compared by BundleMatcher (real paths, case folded on a case-insensitive volume). A process is named by
    /// libproc's path of its executable, else by the path it was started with (KERN_PROCARGS2, which `ps` shows the
    /// `subset` command, and which stays when the executable was deleted or replaced since). One that has exited or is
    /// another user's (which `ps` cannot name either, and Subset cannot ask to quit) does not count. One of this user's
    /// that runs and cannot be named either way refuses when its short name (p_comm, the first 16 bytes of the file it
    /// runs) is that of a file in the bundle; one whose short name is not cannot be the bundle's and does not count.
    public func processes(inside bundle: URL) throws -> [pid_t] {
        try Self.processes(inside: bundle, among: Self.allPids(), look: Self.look)
    }

    /// What is known of a process: the path of its executable, or why there is none.
    enum ProcessLook: Equatable {
        case path(String)
        case exited
        case otherUser
        /// One of this user's that runs and cannot be named: its short name (p_comm) and why it cannot be named.
        case unnamed(command: String, code: Int32)
        /// Nothing about it can be read.
        case unknown(Int32)
    }

    /// Those of `pids` whose executable is inside `bundle`, as `look` names them.
    static func processes(inside bundle: URL, among pids: [pid_t], look: (pid_t) -> ProcessLook) throws -> [pid_t] {
        let matcher = BundleMatcher(bundle)
        var commands: Set<String>?
        let unreadable = { (pid: pid_t, code: Int32) in
            InstallFailure(.running, "whether the app is running cannot be read (the executable of pid \(pid): \(String(cString: strerror(code)))), so nothing was changed")
        }
        return try pids.filter { pid in
            guard pid > 0 else { return false }
            switch look(pid) {
            case let .path(path): return matcher.contains(path)
            case .exited, .otherUser: return false
            case let .unnamed(command, code):
                if commands == nil { commands = matcher.commandNames() }
                guard let names = commands else { throw unreadable(pid, code) }
                if names.contains(matcher.fold(command)) { throw unreadable(pid, code) }
                return false
            case let .unknown(code): throw unreadable(pid, code)
            }
        }
    }

    static func look(_ pid: pid_t) -> ProcessLook {
        if let path = executable(of: pid) { return .path(path) }
        let code = errno
        if let path = startPath(of: pid), path.hasPrefix("/") { return .path(BundleMatcher.canonical(path)) }
        // The kernel's process record, which `ps` reads too: unlike PROC_PIDTBSDINFO it is given for another user's
        // process (that refuses with EPERM), so such a process is never taken for an unreadable one of this user.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return .unknown(errno) }
        // No record: it has exited. SZOMB (5): exited, not yet reaped.
        if size == 0 || info.kp_proc.p_stat == 5 { return .exited }
        let uid = getuid()
        guard info.kp_eproc.e_ucred.cr_uid == uid || info.kp_eproc.e_pcred.p_ruid == uid else { return .otherUser }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return .unnamed(command: command, code: code)
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
        let unreadable = { (why: String) in InstallFailure(.running, "whether the app is running cannot be read (\(why)), so nothing was changed") }
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

    public func quit(_ bundle: URL, timeout: TimeInterval) async throws -> (left: [pid_t], asked: Bool) {
        let mine = Set(try processes(inside: bundle))
        let matcher = BundleMatcher(bundle)
        let asked = await MainActor.run {
            let apps = Self.targets(NSWorkspace.shared.runningApplications, pids: mine, matcher: matcher, own: getpid()) {
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

    /// The running apps to ask to quit: each whose pid was found inside the bundle and whose executable or bundle, as the
    /// system reports it now, is that bundle's too, so a pid that exited and was given to another app is never asked.
    /// This app is never asked to quit itself (the installer refuses such a copy first); it stays in what is left.
    static func targets<App>(_ apps: [App], pids: Set<pid_t>, matcher: BundleMatcher, own: pid_t, _ identity: (App) -> (pid_t, [URL?])) -> [App] {
        apps.filter { app in
            let (pid, urls) = identity(app)
            return pid != own && pids.contains(pid) && urls.contains { $0.map { matcher.contains($0.path + "/") } ?? false }
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

    public func reopen(_ bundle: URL) async -> String? {
        do {
            _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: NSWorkspace.OpenConfiguration())
            return nil
        } catch {
            return error.localizedDescription
        }
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

    func fold(_ text: String) -> String { foldsCase ? text.lowercased() : text }

    /// Whether `path` (a canonical one, as libproc and `look` give) is inside the bundle.
    func contains(_ path: String) -> Bool {
        let path = fold(path)
        return roots.contains { path.hasPrefix($0) }
    }

    /// The short names (p_comm: the first 16 bytes of the file name) of the executables and links in the bundle, or nil
    /// when it cannot be read whole.
    func commandNames() -> Set<String>? {
        var failed = false
        guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil, errorHandler: { _, _ in
            failed = true
            return false
        }) else { return nil }
        var names: Set<String> = []
        for case let url as URL in walker {
            var status = stat()
            guard lstat(url.path, &status) == 0 else { continue }
            let type = status.st_mode & S_IFMT
            guard type == S_IFLNK || (type == S_IFREG && status.st_mode & 0o111 != 0) else { continue }
            names.insert(fold(String(decoding: Array(url.lastPathComponent.utf8.prefix(Int(MAXCOMLEN))), as: UTF8.self)))
        }
        return failed ? nil : names
    }

    /// `path` (absolute) with every link resolved as far as it exists, and `.`, `..` and repeated slashes removed.
    static func canonical(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        for count in stride(from: parts.count, through: 0, by: -1) {
            guard let real = AppInstaller.realPath("/" + parts.prefix(count).joined(separator: "/")) else { continue }
            var result = real.split(separator: "/").map(String.init)
            for part in parts.dropFirst(count) {
                switch part {
                case ".": continue
                case "..": _ = result.popLast()
                default: result.append(part)
                }
            }
            return "/" + result.joined(separator: "/")
        }
        return path
    }
}
