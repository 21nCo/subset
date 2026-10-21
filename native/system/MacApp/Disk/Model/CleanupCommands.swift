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

/// A tool command ready to show and run: the candidate path that was found, and, for Docker, the local socket it is
/// pinned to.
public struct ResolvedCommand: Equatable, Sendable {
    public let tool: CleanupTool
    /// The fixed candidate path that is run.
    public let executable: String
    /// Where that path leads when it is a link (Homebrew links its tools into `bin`), shown beside it.
    public let realExecutable: String?
    /// The real path of the current Docker context's socket, as `unix://…`, which `DOCKER_HOST` pins the command to.
    public let dockerEndpoint: String?

    public var arguments: [String] { tool.arguments }

    /// The command as it runs: the path, then the arguments.
    public var commandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// The last lines a command printed, standard output then standard error, for the result. It is shown only, never
/// logged or kept past the session.
public struct CommandExcerpt: Equatable, Sendable {
    public let lines: [String]
    /// The lines before `lines` that are not shown.
    public let omitted: Int

    init(_ output: CommandOutput, limit: Int = CleanupCommands.outputLineLimit) {
        let all = [output.stdout, output.stderr].flatMap { data in
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

/// How a tool command ended.
public enum CommandCleanupOutcome: Equatable, Sendable {
    /// It exited; a status other than 0 is a failure.
    case exited(status: Int32, output: CommandExcerpt)
    case timedOut(seconds: Int)
    case launchFailed(String)
    case outputTooLarge
    case cancelled
    /// It was not run: the program is no longer at the path the preview showed, or the command is not allowed.
    case refused(String)
}

/// Finds and runs the allowlisted tool commands.
public struct CleanupCommands: Sendable {
    public static let timeout: Duration = .seconds(600)
    public static let outputLineLimit = 200

    public let home: String
    let runner: any CommandRunning
    let timeout: Duration
    let candidates: @Sendable (CleanupTool) -> [String]
    /// The Docker CLI and its current local socket, or why there are none.
    let dockerTarget: @Sendable () -> Result<(executable: String, endpoint: String), ContainerUnavailable>

    /// Commands run in a process group of their own (`ProcessGroupRunner`), so a result comes only once the tool and
    /// every program it started have exited.
    public init(home: String, runner: any CommandRunning = ProcessGroupRunner()) {
        self.init(home: home, runner: runner, timeout: Self.timeout, candidates: { $0.candidatePaths(home: home) },
                  dockerTarget: { DockerCLI(home: home).localTarget() })
    }

    init(home: String, runner: any CommandRunning, timeout: Duration,
         candidates: @escaping @Sendable (CleanupTool) -> [String],
         dockerTarget: @escaping @Sendable () -> Result<(executable: String, endpoint: String), ContainerUnavailable>) {
        self.home = home
        self.runner = runner
        self.timeout = timeout
        self.candidates = candidates
        self.dockerTarget = dockerTarget
    }

    /// The first candidate path that is an executable regular file, following a link only to check it; for Docker,
    /// the CLI the container breakdown would use with its context's socket, which must be on this Mac.
    public func resolve(_ tool: CleanupTool) -> Result<ResolvedCommand, CleanupCommandUnavailable> {
        let paths = candidates(tool)
        if tool == .docker {
            switch dockerTarget() {
            case let .failure(reason): return .failure(.docker(reason.reason))
            case let .success((executable, endpoint)):
                guard paths.contains(executable) else { return .failure(.notFound(tool: tool, paths: paths)) }
                return .success(ResolvedCommand(tool: tool, executable: executable, realExecutable: Self.link(executable),
                                                dockerEndpoint: endpoint))
            }
        }
        guard let executable = paths.first(where: Self.isExecutable) else {
            return .failure(.notFound(tool: tool, paths: paths))
        }
        return .success(ResolvedCommand(tool: tool, executable: executable, realExecutable: Self.link(executable),
                                        dockerEndpoint: nil))
    }

    /// Runs a command the preview showed, after finding it again: one no longer at the same path, or no longer
    /// leading to the same program or socket, is not run.
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
        guard !Task.isCancelled else { return .cancelled }
        switch await runner.run(command.executable, arguments: command.arguments, environment: environment(for: command),
                                timeout: timeout) {
        case let .success(output): return .exited(status: output.status, output: CommandExcerpt(output))
        case .failure(.timedOut): return .timedOut(seconds: Int(timeout.components.seconds))
        case let .failure(.launchFailed(message)): return .launchFailed(message)
        case .failure(.outputTooLarge): return .outputTooLarge
        case .failure(.cancelled): return .cancelled
        }
    }

    /// A fixed environment, nothing inherited: the home folder, the user, a `PATH` starting with the program's own
    /// folder (npm, pnpm, and Yarn are scripts run by the `node` beside them), and settings that turn off the tools'
    /// update checks and hints. Docker is pinned to the socket checked for the preview.
    func environment(for command: ResolvedCommand) -> [String: String] {
        let folder = (command.executable as NSString).deletingLastPathComponent
        var environment = ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
                           "PATH": "\(folder):/usr/bin:/bin:/usr/sbin:/sbin"]
        switch command.tool {
        case .brew:
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["HOMEBREW_NO_ANALYTICS"] = "1"
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        case .npm, .pnpm:
            environment["npm_config_update_notifier"] = "false"
        case .docker:
            environment["DOCKER_HOST"] = command.dockerEndpoint
            environment["DOCKER_CLI_HINTS"] = "false"
        case .xcrun, .yarn:
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
