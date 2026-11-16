import AppKit
import Darwin
import Foundation

/// Moves an app to the Trash; `SystemTrash` uses the user's Trash, tests a folder.
public protocol Trashing: Sendable {
    /// Moves `bundle` to the Trash and returns where it is there. Never deletes it.
    func trash(_ bundle: URL, appName: String, at date: Date) throws -> URL
}

/// The user's Trash, through FileManager.trashItem (the Trash of the bundle's volume). A copy set aside under a hidden
/// name is renamed in the Trash to `<appName> <date> <time>.app`, as the `subset` command names it, so it can be seen.
public struct SystemTrash: Trashing {
    public init() {}

    public func trash(_ bundle: URL, appName: String, at date: Date) throws -> URL {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: bundle, resultingItemURL: &result)
        } catch {
            throw InstallFailure(.trash, "\(bundle.path) cannot be moved to the Trash (\(error.localizedDescription))")
        }
        guard let trashed = result as URL? else { throw InstallFailure(.trash, "the Trash did not say where \(bundle.path) went") }
        guard trashed.lastPathComponent.hasPrefix(".") else { return trashed }
        return (try? FolderTrash.renameInto(trashed.deletingLastPathComponent(), trashed, appName: appName, at: date)) ?? trashed
    }
}

/// A folder standing in for the Trash (tests and the CI install check): the bundle is renamed into it as
/// `<appName> <date> <time>.app`, never over anything already there.
public struct FolderTrash: Trashing {
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func trash(_ bundle: URL, appName: String, at date: Date) throws -> URL {
        try Self.renameInto(folder, bundle, appName: appName, at: date)
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
    /// processes cannot be read, so a running app is never taken for one that is not.
    func processes(inside bundle: URL) throws -> [pid_t]
    /// Asks each running app at `bundle` to quit (NSRunningApplication.terminate(), never a force quit), then waits up
    /// to `timeout` seconds for every process inside it to exit; returns the pids still running.
    func quit(_ bundle: URL, timeout: TimeInterval) async throws -> [pid_t]
    /// Opens the app at `bundle` again after it was quit for an update; returns why it could not, or nil.
    func reopen(_ bundle: URL) async -> String?
}

/// The processes from libproc (each pid's executable path), quit with NSRunningApplication.terminate().
public struct WorkspaceRunningApps: RunningAppControlling {
    public init() {}

    /// Every process whose executable is inside `bundle`, this one included: a copy holding this app is running too.
    public func processes(inside bundle: URL) throws -> [pid_t] {
        let roots = Set([bundle.path, bundle.resolvingSymlinksInPath().path]).map { $0 + "/" }
        return try Self.allPids().filter { pid in
            guard pid > 0, let executable = Self.executable(of: pid) else { return false }
            return roots.contains { executable.hasPrefix($0) }
        }
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

    public func quit(_ bundle: URL, timeout: TimeInterval) async throws -> [pid_t] {
        let mine = Set(try processes(inside: bundle))
        await MainActor.run {
            // This app is never asked to quit itself (the installer refuses such a copy first); it stays in what is left.
            for app in NSWorkspace.shared.runningApplications where mine.contains(app.processIdentifier) && app.processIdentifier != getpid() {
                app.terminate()
            }
        }
        let until = Date().addingTimeInterval(timeout)
        while true {
            let left = try processes(inside: bundle)
            if left.isEmpty || Date() >= until { return left }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
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
