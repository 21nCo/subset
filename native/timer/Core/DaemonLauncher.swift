import Darwin
import Foundation

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

    /// Returns the daemon's process ID. A second daemon started while one runs exits at once with "already running".
    @discardableResult
    public static func launch(node: String, cli: String, paths: DaemonPaths,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> pid_t {
        do {
            // The daemon tightens the folder to 0700 itself; creating it so keeps the log private from the start.
            try FileManager.default.createDirectory(atPath: paths.dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Keep one previous log of up to 1 MiB.
            if let size = try? FileManager.default.attributesOfItem(atPath: paths.log)[.size] as? Int, size > maxLogBytes {
                _ = rename(paths.log, paths.log + ".1")
            }
        } catch {
            throw LaunchError.dataDirectory(error.localizedDescription)
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
        let child = pid
        Thread.detachNewThread {
            var exitStatus: Int32 = 0
            waitpid(child, &exitStatus, 0)
        }
        return child
    }
}
