import Darwin
import Foundation
import SystemCore

/// A developer tool a cleanup may run, each with its one allowed argument vector. Nothing else is ever run, and never
/// through a shell or `PATH`.
public enum CleanupTool: String, CaseIterable, Sendable {
    case xcrun
    case brew
    case npm
    case pnpm
    case yarn
    case docker

    /// The arguments after the program's name, exactly.
    public var arguments: [String] {
        switch self {
        case .xcrun: ["simctl", "delete", "unavailable"]
        case .brew: ["cleanup"]
        case .npm: ["cache", "clean", "--force"]
        case .pnpm: ["store", "prune"]
        case .yarn: ["cache", "clean"]
        case .docker: ["image", "prune", "-f"]
        }
    }

    /// The program's name, then its arguments, as a rule's cleanup names it.
    public var vector: [String] { [rawValue] + arguments }

    /// The tool whose vector this is exactly, or `nil` for any other command or argument.
    public static func allowed(_ vector: [String]) -> CleanupTool? {
        allCases.first { $0.vector == vector }
    }

    /// The fixed paths the program is looked for at, in order: Homebrew's on Apple silicon, then on Intel, for the
    /// Homebrew-installed tools; Xcode's shim; and the Docker CLI's paths that the container breakdown uses.
    public func candidatePaths(home: String) -> [String] {
        switch self {
        case .xcrun: ["/usr/bin/xcrun"]
        case .brew, .npm, .pnpm, .yarn: ["/opt/homebrew/bin/" + rawValue, "/usr/local/bin/" + rawValue]
        case .docker: DockerCLI.candidatePaths(home: home)
        }
    }
}

/// A tool command ready to show and run: the candidate path that was found, which file it was, and, for Docker, the
/// local socket it is pinned to.
public struct ResolvedCommand: Equatable, Sendable {
    public let tool: CleanupTool
    /// The fixed candidate path that is run.
    public let executable: String
    /// Where that path leads when it is a link (Homebrew links its tools into `bin`), shown beside it.
    public let realExecutable: String?
    /// The real path of the current Docker context's socket, as `unix://…`, which `DOCKER_HOST` pins the command to.
    public let dockerEndpoint: String?
    /// The files the path was when it was found, so another program put at the same path is not the same command.
    let files: ExecutableFiles

    public var arguments: [String] { tool.arguments }

    /// The command as it runs: the path, then the arguments.
    public var commandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// The files a command's path led to when it was found: the path itself, a link or not, and the program it leads to,
/// each by volume, inode, and the time its contents or attributes last changed, which a write in place changes too.
struct ExecutableFiles: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let changed: timespec

        static func == (lhs: File, rhs: File) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.changed.tv_sec == rhs.changed.tv_sec
                && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            changed = info.st_ctimespec
        }
    }

    let path: File
    let program: File

    /// The files at `path` now (`lstat`, then `stat`), or `nil` when either cannot be read.
    static func read(_ path: String) -> ExecutableFiles? {
        var own = stat()
        var target = stat()
        guard lstat(path, &own) == 0, stat(path, &target) == 0 else { return nil }
        return ExecutableFiles(path: File(own), program: File(target))
    }
}

/// The last lines a command printed, standard output then standard error, for the result. It is shown only, never
/// logged or kept past the session.
public struct CommandExcerpt: Equatable, Sendable {
    public let lines: [String]
    /// The lines before `lines` that are not shown.
    public let omitted: Int

    static let none = CommandExcerpt(stdout: Data(), stderr: Data())

    init(stdout: Data, stderr: Data, limit: Int = CleanupCommands.outputLineLimit) {
        let all = [stdout, stderr].flatMap { data in
            var lines = String(decoding: data, as: UTF8.self)
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            // The newline ending the last line does not start another.
            if lines.last?.isEmpty == true { lines.removeLast() }
            return lines
        }
        lines = Array(all.suffix(limit))
        omitted = all.count - lines.count
    }
}

/// How a tool command ended, with what it printed before it exited or was stopped.
public enum CommandCleanupOutcome: Equatable, Sendable {
    /// It exited; a status other than 0 is a failure.
    case exited(status: Int32, output: CommandExcerpt)
    case timedOut(seconds: Int, output: CommandExcerpt)
    case launchFailed(String)
    case outputTooLarge(output: CommandExcerpt)
    case cancelled(output: CommandExcerpt)
    /// It was not run: the program is no longer the one the preview showed, or the command is not allowed.
    case refused(String)

    public var output: CommandExcerpt? {
        switch self {
        case let .exited(_, output), let .timedOut(_, output), let .outputTooLarge(output), let .cancelled(output): output
        case .launchFailed, .refused: nil
        }
    }

    /// The command ran, so it may have changed something; refused and unstarted commands did nothing.
    public var ran: Bool { output != nil }
}

/// Finds and runs the allowlisted tool commands.
public struct CleanupCommands: Sendable {
    public static let timeout: Duration = .seconds(600)
    public static let outputLineLimit = 200
    /// Every command runs here, where no project's settings (`package.json`, `.npmrc`, `.yarnrc`) apply.
    public static let workingDirectory = "/"

    public let home: String
    let runner: any GroupCommandRunning
    let timeout: Duration
    let candidates: @Sendable (CleanupTool) -> [String]
    /// The Docker CLI and its current local socket, or why there are none.
    let dockerTarget: @Sendable () -> Result<(executable: String, endpoint: String), ContainerUnavailable>

    /// Commands run in a process group of their own (`ProcessGroupRunner`), so a result comes only once the tool and
    /// every program it started have exited.
    public init(home: String, runner: any GroupCommandRunning = ProcessGroupRunner()) {
        self.init(home: home, runner: runner, timeout: Self.timeout, candidates: { $0.candidatePaths(home: home) },
                  dockerTarget: { DockerCLI(home: home).localTarget() })
    }

    init(home: String, runner: any GroupCommandRunning, timeout: Duration,
         candidates: @escaping @Sendable (CleanupTool) -> [String],
         dockerTarget: @escaping @Sendable () -> Result<(executable: String, endpoint: String), ContainerUnavailable>) {
        self.home = home
        self.runner = runner
        self.timeout = timeout
        self.candidates = candidates
        self.dockerTarget = dockerTarget
    }

    /// The first candidate path that is an executable regular file, following a link only to check it; for Docker,
    /// the CLI the container breakdown would use with its context's socket, which must be on this Mac. It records which
    /// files the path and its program were, so a program replaced since is not run.
    public func resolve(_ tool: CleanupTool) -> Result<ResolvedCommand, CleanupCommandUnavailable> {
        let paths = candidates(tool)
        if tool == .docker {
            switch dockerTarget() {
            case let .failure(reason): return .failure(.docker(reason.reason))
            case let .success((executable, endpoint)):
                guard paths.contains(executable), let files = ExecutableFiles.read(executable)
                else { return .failure(.notFound(tool: tool, paths: paths)) }
                return .success(ResolvedCommand(tool: tool, executable: executable, realExecutable: Self.link(executable),
                                                dockerEndpoint: endpoint, files: files))
            }
        }
        guard let executable = paths.first(where: Self.isExecutable), let files = ExecutableFiles.read(executable) else {
            return .failure(.notFound(tool: tool, paths: paths))
        }
        return .success(ResolvedCommand(tool: tool, executable: executable, realExecutable: Self.link(executable),
                                        dockerEndpoint: nil, files: files))
    }

    /// Runs a command the preview showed, after finding it again: one no longer at the same path, no longer the same
    /// files there, or no longer leading to the same program or socket, is not run.
    func run(_ command: ResolvedCommand) async -> CommandCleanupOutcome {
        guard CleanupTool.allowed(command.tool.vector) == command.tool,
              candidates(command.tool).contains(command.executable) else {
            return .refused("\(command.commandLine) is not an allowed command.")
        }
        switch resolve(command.tool) {
        case let .failure(reason):
            return .refused(reason.text)
        case let .success(now) where now != command:
            return .refused("\(command.tool.rawValue) has changed since the preview (now \(now.commandLine)"
                + (now.dockerEndpoint.map { " on \($0)" } ?? "") + "), so it was not run. Open the cleanup again.")
        case .success:
            break
        }
        guard !Task.isCancelled else { return .cancelled(output: .none) }
        let result = await runner.run(command.executable, arguments: command.arguments,
                                      environment: environment(for: command), workingDirectory: Self.workingDirectory,
                                      timeout: timeout)
        let output = CommandExcerpt(stdout: result.stdout, stderr: result.stderr)
        switch result.ending {
        case let .success(status): return .exited(status: status, output: output)
        case .failure(.timedOut): return .timedOut(seconds: Int(timeout.components.seconds), output: output)
        case let .failure(.launchFailed(message)): return .launchFailed(message)
        case .failure(.outputTooLarge): return .outputTooLarge(output: output)
        case .failure(.cancelled): return .cancelled(output: output)
        }
    }

    /// A fixed environment, nothing inherited: the home folder, the user, a `PATH` starting with the program's own
    /// folder (npm, pnpm, and Yarn are scripts run by the `node` beside them), and settings that turn off the tools'
    /// update checks and hints. Docker is pinned to the socket checked for the preview. The package managers are kept
    /// from handing the command to another program: Yarn's `yarn-path` (`YARN_IGNORE_PATH`), pnpm's switch to the
    /// version a project names, and Corepack, whose shims would otherwise download or pin a version.
    func environment(for command: ResolvedCommand) -> [String: String] {
        let folder = (command.executable as NSString).deletingLastPathComponent
        var environment = ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
                           "PATH": "\(folder):/usr/bin:/bin:/usr/sbin:/sbin"]
        switch command.tool {
        case .brew:
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["HOMEBREW_NO_ANALYTICS"] = "1"
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        case .npm, .pnpm, .yarn:
            environment["npm_config_update_notifier"] = "false"
            environment["npm_config_manage_package_manager_versions"] = "false"
            environment["YARN_IGNORE_PATH"] = "1"
            environment["COREPACK_ENABLE_NETWORK"] = "0"
            environment["COREPACK_ENABLE_AUTO_PIN"] = "0"
        case .docker:
            environment["DOCKER_HOST"] = command.dockerEndpoint
            environment["DOCKER_CLI_HINTS"] = "false"
        case .xcrun:
            break
        }
        return environment
    }

    static func isExecutable(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }

    static func link(_ path: String) -> String? {
        CleanupItem.realPath(path).flatMap { $0 == path ? nil : $0 }
    }
}

/// Why a tool command cannot run.
public enum CleanupCommandUnavailable: Error, Equatable, Sendable {
    case notFound(tool: CleanupTool, paths: [String])
    /// The Docker CLI or a local daemon was not found.
    case docker(String)

    public var text: String {
        switch self {
        case let .notFound(tool, paths):
            "No \(tool.rawValue) at " + paths.joined(separator: " or ") + ", so System cannot run its cleanup."
        case let .docker(reason):
            reason
        }
    }
}
