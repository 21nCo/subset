import CryptoKit
import Darwin
import Foundation

/// Asks the local Docker-compatible CLI, under its current context, for the running containers and their usage
/// inside the VM. Only a CLI at one of the fixed candidate paths is run, never one found through `PATH`, and only
/// with a context whose endpoint is a socket on this Mac: remote contexts are not supported, and System makes no
/// network connection of its own.
public struct DockerCLI: Sendable {
    public static let timeout: Duration = .seconds(5)
    public static let listingArguments = ["ps", "--format", "{{json .}}"]
    public static let statsArguments = ["stats", "--no-stream", "--format", "{{json .}}"]

    /// In the order tried: Docker Desktop's and Colima's usual links, OrbStack's, and Docker Desktop's own copy.
    public static func candidatePaths(home: String) -> [String] {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.orbstack/bin/docker",
         "/Applications/Docker.app/Contents/Resources/bin/docker"]
    }

    public let home: String
    public let candidates: [String]
    public let runner: any CommandRunning
    public let timeout: Duration

    public init(home: String = NSHomeDirectory(), candidates: [String]? = nil,
                runner: any CommandRunning = ProcessCommandRunner(), timeout: Duration = DockerCLI.timeout) {
        self.home = home
        self.candidates = candidates ?? Self.candidatePaths(home: home)
        self.runner = runner
        self.timeout = timeout
    }

    /// The first candidate that is an executable regular file.
    public func executable() -> String? {
        candidates.first { path in
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
        }
    }

    /// Runs `docker ps`, then `docker stats`, each with `timeout`, and joins their rows. Any failure gives a report
    /// without a breakdown and with the reason.
    public func report(at date: Date = Date()) async -> ContainerReport {
        guard let cli = executable() else { return ContainerReport(observedAt: date, outcome: .unavailable(.cliNotFound)) }
        let context: DockerContext
        switch DockerContextReader(home: home).current() {
        case let .success(found): context = found
        case let .failure(reason): return ContainerReport(observedAt: date, executable: cli, outcome: .unavailable(reason))
        }
        let outcome: ContainerOutcome
        switch await run(cli, Self.listingArguments) {
        case let .failure(reason): outcome = .unavailable(reason)
        case let .success(listingText):
            switch await run(cli, Self.statsArguments) {
            case let .failure(reason): outcome = .unavailable(reason)
            case let .success(statsText):
                let listing = DockerOutput.listing(listingText)
                let stats = DockerOutput.stats(statsText)
                if listing.isUnparsable {
                    outcome = .unavailable(.unparsableOutput(command: Self.commandName(Self.listingArguments)))
                } else if stats.isUnparsable {
                    outcome = .unavailable(.unparsableOutput(command: Self.commandName(Self.statsArguments)))
                } else {
                    outcome = .breakdown(ContainerBreakdown(listing: listing, stats: stats))
                }
            }
        }
        return ContainerReport(observedAt: date, executable: cli, context: context, outcome: outcome)
    }

    /// The environment the CLI runs with: `HOME` and a fixed `PATH`, nothing inherited, so `DOCKER_HOST`,
    /// `DOCKER_CONTEXT`, and `DOCKER_CONFIG` cannot point it elsewhere than the context checked here.
    var environment: [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DOCKER_CLI_HINTS": "false"]
    }

    private func run(_ cli: String, _ arguments: [String]) async -> Result<String, ContainerUnavailable> {
        let command = Self.commandName(arguments)
        switch await runner.run(cli, arguments: arguments, environment: environment, timeout: timeout) {
        case let .failure(.launchFailed(message)): return .failure(.launchFailed(command: command, message: message))
        case .failure(.timedOut): return .failure(.timedOut(command: command, seconds: Self.seconds(timeout)))
        case .failure(.outputTooLarge): return .failure(.outputTooLarge(command: command))
        case let .success(output):
            guard output.status == 0 else {
                let message = Self.firstLine(output.stderr)
                if Self.daemonUnreachableMarkers.contains(where: message.localizedCaseInsensitiveContains) {
                    return .failure(.daemonNotRunning(message: message))
                }
                return .failure(.failed(command: command, status: output.status, message: message))
            }
            guard let text = String(data: output.stdout, encoding: .utf8) else {
                return .failure(.unparsableOutput(command: command))
            }
            return .success(text)
        }
    }

    /// What the CLI prints when the daemon is stopped or its socket is missing.
    static let daemonUnreachableMarkers = ["Cannot connect to the Docker daemon", "Is the docker daemon running", "error during connect"]

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func commandName(_ arguments: [String]) -> String {
        "docker " + (arguments.first ?? "")
    }

    /// The first non-empty line of the CLI's error output, at most 300 characters.
    static func firstLine(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return String((line ?? "").prefix(300))
    }
}

/// The Docker context the CLI uses: its name, its endpoint, and the runtime whose VM that endpoint reaches.
public struct DockerContext: Equatable, Sendable {
    public let name: String
    /// The Docker endpoint, such as `unix:///Users/me/.orbstack/run/docker.sock`.
    public let host: String
    /// From the socket's real path; `nil` when it belongs to no recognized runtime.
    public let runtime: ContainerRuntime?
}

/// Reads the current context the way the CLI does without `DOCKER_HOST` or `DOCKER_CONTEXT`: `currentContext` in
/// `~/.docker/config.json`, whose endpoint is in `~/.docker/contexts/meta/<sha256 of the name>/meta.json`. No context,
/// or `default`, is the default socket `/var/run/docker.sock`.
struct DockerContextReader {
    static let defaultHost = "unix:///var/run/docker.sock"
    static let fileLimit = 1 << 20
    let home: String

    func current() -> Result<DockerContext, ContainerUnavailable> {
        let configPath = home + "/.docker/config.json"
        var name = "default"
        switch Self.readJSON(configPath) {
        case let .success(config):
            if let current = config["currentContext"] as? String, !current.isEmpty { name = current }
        case .failure(.missing):
            break
        case let .failure(failure):
            return .failure(.contextUnreadable(path: configPath, message: failure.message))
        }
        guard name != "default" else { return .success(Self.context(name: name, host: Self.defaultHost)) }

        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let metaPath = home + "/.docker/contexts/meta/\(digest)/meta.json"
        let meta: [String: Any]
        switch Self.readJSON(metaPath) {
        case let .success(found): meta = found
        case let .failure(failure): return .failure(.contextUnreadable(path: metaPath, message: failure.message))
        }
        guard let endpoints = meta["Endpoints"] as? [String: Any], let docker = endpoints["docker"] as? [String: Any],
              let host = docker["Host"] as? String, !host.isEmpty else {
            return .failure(.contextUnreadable(path: metaPath, message: "no Docker endpoint"))
        }
        guard host.hasPrefix("unix://") else { return .failure(.remoteContext(name: name, host: host)) }
        return .success(Self.context(name: name, host: host))
    }

    private static func context(name: String, host: String) -> DockerContext {
        let socket = String(host.dropFirst("unix://".count))
        let real = realpath(socket, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        return DockerContext(name: name, host: host, runtime: ContainerRuntime.owning(socketPath: real ?? socket))
    }

    enum ReadFailure: Error {
        case missing
        case unreadable(String)

        var message: String {
            switch self {
            case .missing: "not found"
            case let .unreadable(message): message
            }
        }
    }

    /// A JSON object from a regular file of at most `fileLimit` bytes, opened without blocking so a FIFO in its
    /// place cannot stall the caller.
    static func readJSON(_ path: String) -> Result<[String: Any], ReadFailure> {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable(String(cString: strerror(errno))))
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(.unreadable("not a regular file")) }
        guard info.st_size <= fileLimit else { return .failure(.unreadable("larger than 1 MiB")) }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { return .failure(.unreadable("could not be read")) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.unreadable("not a JSON object"))
        }
        return .success(object)
    }
}

/// One run of the CLI: when, which executable and context, and the breakdown or the reason there is none.
public struct ContainerReport: Equatable, Sendable {
    public let observedAt: Date
    public let executable: String?
    public let context: DockerContext?
    public let outcome: ContainerOutcome

    public init(observedAt: Date, executable: String? = nil, context: DockerContext? = nil, outcome: ContainerOutcome) {
        self.observedAt = observedAt
        self.executable = executable
        self.context = context
        self.outcome = outcome
    }

    /// What this report says about one running runtime's VM. The context's endpoint names the runtime; an endpoint
    /// that names none (a custom socket path) is taken to be the only running runtime's, when only one runs.
    public func status(of runtime: ContainerRuntime, running: [ContainerRuntime]) -> ContainerBreakdownStatus {
        guard let context else {
            if case let .unavailable(reason) = outcome { return .unavailable(reason) }
            return .notMeasured
        }
        guard let target = context.runtime ?? (running.count == 1 ? running.first : nil) else {
            return .unavailable(.contextNotRecognized(name: context.name, host: context.host))
        }
        guard target == runtime else { return .otherContext(name: context.name, runtime: target) }
        switch outcome {
        case let .breakdown(breakdown): return .measured(breakdown)
        case let .unavailable(reason): return .unavailable(reason)
        }
    }
}

public enum ContainerOutcome: Equatable, Sendable {
    case breakdown(ContainerBreakdown)
    case unavailable(ContainerUnavailable)
}

/// What a VM group shows beneath it.
public enum ContainerBreakdownStatus: Equatable, Sendable {
    /// The CLI has not run since the window opened, or no report covers this runtime yet.
    case notMeasured
    case measured(ContainerBreakdown)
    case unavailable(ContainerUnavailable)
    /// The current context reaches another runtime's VM, so this one's containers are not listed.
    case otherContext(name: String, runtime: ContainerRuntime)
}

/// Why a VM group has no container breakdown.
public enum ContainerUnavailable: Error, Equatable, Sendable {
    case cliNotFound
    case contextUnreadable(path: String, message: String)
    case remoteContext(name: String, host: String)
    case contextNotRecognized(name: String, host: String)
    case daemonNotRunning(message: String)
    case timedOut(command: String, seconds: Double)
    case failed(command: String, status: Int32, message: String)
    case launchFailed(command: String, message: String)
    case outputTooLarge(command: String)
    case unparsableOutput(command: String)

    public var reason: String {
        switch self {
        case .cliNotFound:
            "No docker command in /usr/local/bin, /opt/homebrew/bin, ~/.orbstack/bin, or Docker.app."
        case let .contextUnreadable(path, message):
            "Could not read the current Docker context from \(path): \(message)."
        case let .remoteContext(name, host):
            "The current Docker context “\(name)” points at \(host), which is not on this Mac; remote contexts are not supported."
        case let .contextNotRecognized(name, host):
            "The current Docker context “\(name)” (\(host)) does not belong to a recognized VM."
        case let .daemonNotRunning(message):
            "The Docker daemon is not running." + (message.isEmpty ? "" : " \(message)")
        case let .timedOut(command, seconds):
            "\(command) did not finish within \(seconds.formatted()) seconds."
        case let .failed(command, status, message):
            "\(command) failed with exit status \(status)" + (message.isEmpty ? "." : ": \(message)")
        case let .launchFailed(command, message):
            "\(command) could not be started: \(message)"
        case let .outputTooLarge(command):
            "\(command) printed more output than System reads."
        case let .unparsableOutput(command):
            "Could not read the output of \(command)."
        }
    }
}

/// Runs the CLI at most once every 10 seconds, only while the main window is visible and a runtime's VM is
/// running, and never twice at once. With only the menu bar in use it never runs.
public actor ContainerPoller {
    public static let minimumInterval: Duration = .seconds(10)
    private let cli: DockerCLI
    private var lastStart: ContinuousClock.Instant?
    private var isRunning = false

    public init(cli: DockerCLI = DockerCLI()) {
        self.cli = cli
    }

    /// A new report, or `nil` when the CLI did not run: the window is not visible, no runtime runs, a run is in
    /// progress, or the last one started less than `minimumInterval` before `now`.
    public func refresh(cadence: SamplingCadence, runningRuntimes: [ContainerRuntime],
                        now: ContinuousClock.Instant = .now) async -> ContainerReport? {
        guard cadence == .mainWindowVisible, !runningRuntimes.isEmpty, !isRunning else { return nil }
        if let lastStart, now - lastStart < Self.minimumInterval { return nil }
        isRunning = true
        lastStart = now
        defer { isRunning = false }
        return await cli.report()
    }
}
