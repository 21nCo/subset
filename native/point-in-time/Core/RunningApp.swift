import Darwin
import Foundation

/// Whether pointInTime is running, as `point-in-time status` reports it in `tracking.appRunning`.
public enum RunningApp {
    /// Decides from the bundle identifiers of the running applications this process can list. An empty list means the
    /// list could not be read, as inside an agent's sandbox, which hides every app, Finder included. Then the app counts
    /// as running when a process runs the executable of a bundle with the app's identifier, and as unknown (nil)
    /// otherwise, never as not running.
    public static func isRunning(listedBundleIdentifiers: [String?], processExecutables: () -> [URL],
                                 bundleIdentifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) -> Bool? {
        if !listedBundleIdentifiers.isEmpty { return listedBundleIdentifiers.contains(StoredSettings.domain) }
        let found = processExecutables().contains { executable in
            let macOS = executable.deletingLastPathComponent()
            let contents = macOS.deletingLastPathComponent()
            return macOS.lastPathComponent == "MacOS" && contents.lastPathComponent == "Contents"
                && bundleIdentifier(contents.deletingLastPathComponent()) == StoredSettings.domain
        }
        return found ? true : nil
    }

    /// The executables of the running processes whose paths this process can read, from libproc.
    public static func processExecutables() -> [URL] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let listed = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard listed > 0 else { return [] }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(listed)).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            return URL(fileURLWithPath: String(cString: path))
        }
    }
}
