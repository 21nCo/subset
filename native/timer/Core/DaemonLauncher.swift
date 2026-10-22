import Darwin
import Foundation
import os

/// Starts `node <cli.mjs> daemon run` in its own session, so it keeps running after the app quits, with its
/// output appended to `daemon.log` as the CLI's own client does (packages/timer-cli/src/daemon/client.mjs).
public enum DaemonLauncher {
    static let maxLogBytes = 1024 * 1024

    public enum LaunchError: Error, Equatable, LocalizedError {
        case dataDirectory(String)
        case spawn(Int32)

        public var errorDescription: String? {
            switch self {
            case .dataDirectory(let reason): "Could not prepare the Timer data folder: \(reason)"
            case .spawn(let code): "Could not start the Timer daemon: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Returns the daemon's process. A second daemon started while one runs exits at once with "already running".
    @discardableResult
    public static func launch(node: String, cli: String, paths: DaemonPaths,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LaunchedDaemon {
        try prepare(paths)
        // Keep one previous log of up to 1 MiB.
        if let size = try? FileManager.default.attributesOfItem(atPath: paths.log)[.size] as? Int, size > maxLogBytes {
            _ = rename(paths.log, paths.log + ".1")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, paths.log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session: neither the app's quitting nor a signal to its process group reaches the daemon.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var env = environment
        env["SUBSET_TIMER_DATA_DIR"] = paths.dataDir
        let arguments = [node, cli, "daemon", "run"]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, node, &actions, &attributes, argv, envp)
        guard status == 0 else { throw LaunchError.spawn(status) }
        // Reap it when it exits, so it never lingers as a zombie while the app runs.
        let child = LaunchedDaemon(pid: pid)
        Thread.detachNewThread {
            var exitStatus: Int32 = 0
            waitpid(child.pid, &exitStatus, 0)
            child.markExited()
        }
        return child
    }

    /// The CLI's `ensureDataDir` (paths.mjs), run before anything is written to the folder.
    static func prepare(_ paths: DaemonPaths) throws {
        guard paths.socket.utf8.count <= 103 else {
            throw LaunchError.dataDirectory("The socket path \(paths.socket) is longer than 103 bytes; set SUBSET_TIMER_DATA_DIR to a shorter directory.")
        }
        do {
            try FileManager.default.createDirectory(atPath: paths.dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw LaunchError.dataDirectory(error.localizedDescription)
        }
        var info = stat()
        guard lstat(paths.dataDir, &info) == 0 else { throw LaunchError.dataDirectory(String(cString: strerror(errno))) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw LaunchError.dataDirectory("\(paths.dataDir) is not a directory.") }
        guard info.st_uid == getuid() else { throw LaunchError.dataDirectory("\(paths.dataDir) belongs to another user.") }
        if info.st_mode & 0o777 != 0o700, chmod(paths.dataDir, 0o700) != 0 {
            throw LaunchError.dataDirectory(String(cString: strerror(errno)))
        }
    }
}

/// A daemon process `DaemonLauncher` started; `hasExited` turns true once it ends.
public final class LaunchedDaemon: Sendable {
    public let pid: pid_t
    private let exited = OSAllocatedUnfairLock(initialState: false)

    public init(pid: pid_t) { self.pid = pid }
    public var hasExited: Bool { exited.withLock { $0 } }
    public func markExited() { exited.withLock { $0 = true } }
}

enum DaemonLock {
    /// True while a live process holds `daemon.lock` (client.mjs `lockHeld`, without its check for a reused pid).
    static func held(at path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let match = text.wholeMatch(of: /([0-9]+)\n(?:[0-9a-f]{32}\n(?:[!-~]{1,128}\n)?)?/),
              let pid = pid_t(match.1), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
