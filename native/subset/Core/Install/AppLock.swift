import CryptoKit
import Darwin
import Foundation

/// The per-app lock the `subset` command's install, update and uninstall take (lock.mjs, SET-231), so the command, this
/// app and another copy of it never work on one app at once. Each holder creates its own file,
/// `<key>.<pid>.<random>.lock` in ~/Library/Application Support/Subset/locks (key: the SHA-256 of the bundle ID in hex),
/// exclusively, and only then looks at the others: one whose process still runs refuses this lock; one whose process no
/// longer runs is removed. Within this app, two operations on one app are refused the same way, since both files carry
/// this process's pid.
struct AppLock {
    private let file: String

    /// Takes the lock of `app` in `folder`; throws an InstallFailure (step lock) when another holder runs or the lock
    /// cannot be made.
    init(_ app: CatalogApp, in folder: URL, running: (pid_t) -> Bool = processRuns) throws {
        let key = SHA256.hash(data: Data(app.bundleID.utf8)).map { String(format: "%02x", $0) }.joined()
        let mine = "\(key).\(getpid()).\(Self.random()).lock"
        let path = folder.appendingPathComponent(mine).path
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            _ = "\(getpid())\n".withCString { write(descriptor, $0, strlen($0)) }
            close(descriptor)
        } catch {
            throw InstallFailure(.lock, "its lock cannot be made in \(folder.path) (\(error.localizedDescription))")
        }
        file = path
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            release()
            throw InstallFailure(.lock, "its lock cannot be checked in \(folder.path)")
        }
        for name in names where name != mine {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == key, parts[3] == "lock", parts[2].count == 12, let pid = pid_t(parts[1]), pid > 0 else { continue }
            if pid == getpid() || running(pid) {
                release()
                let who = pid == getpid() ? "Subset is already installing, updating or moving it to the Trash"
                    : "the subset command or another Subset (pid \(pid)) is installing, updating or uninstalling it"
                throw InstallFailure(.lock, "\(who); try again once it has finished")
            }
            if unlink(folder.appendingPathComponent(name).path) != 0, errno != ENOENT {
                release()
                throw InstallFailure(.lock, "the lock \(folder.appendingPathComponent(name).path) of a process that no longer runs cannot be removed; remove it by hand")
            }
        }
    }

    /// Removes this holder's lock file (best effort: one left behind names a process that no longer runs).
    func release() {
        unlink(file)
    }

    /// Whether process `pid` runs (one of another user counts).
    static func processRuns(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// 12 lowercase hex digits.
    static func random() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// A hidden name beside `<appName>.app` in `folder` for a copy this process sets aside, as trash.mjs names them so
    /// that either tool recovers what the other left: `.<appName>.app.subset-<kind>-<pid>-<random>`. `kind` is update
    /// (the installed copy between an update's two renames), trash (the installed copy while it is moved to the Trash) or
    /// old (a replaced copy, never put back).
    static func hiddenName(in folder: URL, appName: String, kind: String) -> URL {
        folder.appendingPathComponent(".\(appName).app.subset-\(kind)-\(getpid())-\(random())")
    }
}
