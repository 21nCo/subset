import Foundation

/// What `RuntimeLocator` asks of the system, so tests can supply a fake one.
public protocol RuntimeSystem: Sendable {
    func isExecutable(_ path: String) -> Bool
    func fileExists(_ path: String) -> Bool
    /// The standard output of `executable` with `arguments`, or nil when it fails or runs longer than `timeout` seconds.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> String?
}

/// Node.js and the Timer CLI the app runs.
public struct Runtime: Equatable, Sendable {
    public enum CLISource: String, Sendable {
        case override = "SUBSET_TIMER_CLI_PATH"
        case bundled = "bundled in the app"
    }

    public var node: String
    public var nodeVersion: String
    public var cli: String
    public var cliSource: CLISource
}

public enum RuntimeProblem: Error, Equatable, Sendable {
    case nodeMissing
    /// `SUBSET_TIMER_CLI_PATH` names a file that does not exist.
    case overrideMissing(String)
    /// The app has no embedded CLI, as in a Debug build made before `npm run build`.
    case bundledMissing(String)

    public var message: String {
        switch self {
        case .nodeMissing: "Node.js \(RuntimeLocator.minimumNode.major).\(RuntimeLocator.minimumNode.minor) or later is required"
        case .overrideMissing(let path): "SUBSET_TIMER_CLI_PATH names \(path), which does not exist"
        case .bundledMissing(let path): "The Timer command-line runtime is missing from the app (\(path)); run npm run build at the repository root and build again"
        }
    }
}

/// Finds Node.js 22.13 or later, the CLI's `engines` (the Homebrew paths, then the login shell with a 5-second limit, which covers nvm and
/// similar managers) and then the CLI (`SUBSET_TIMER_CLI_PATH`, else the copy in the app's Resources).
public struct RuntimeLocator: Sendable {
    public static let minimumNode = (major: 22, minor: 13)
    public static let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
    public static let shellTimeout: TimeInterval = 5

    public var environment: [String: String]
    /// The app bundle's Resources folder.
    public var resources: String?
    public var system: RuntimeSystem

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                resources: String? = Bundle.main.resourcePath, system: RuntimeSystem = ProcessRuntimeSystem()) {
        self.environment = environment
        self.resources = resources
        self.system = system
    }

    public func locate() async -> Result<Runtime, RuntimeProblem> {
        guard let (node, version) = await findNode() else { return .failure(.nodeMissing) }
        switch findCLI() {
        case .success(let (cli, source)): return .success(Runtime(node: node, nodeVersion: version, cli: cli, cliSource: source))
        case .failure(let problem): return .failure(problem)
        }
    }

    /// The first supported Node.js and its version. An older Node in one place does not hide a newer one elsewhere.
    public func findNode() async -> (path: String, version: String)? {
        for candidate in Self.nodeCandidates {
            if let version = await supportedVersion(candidate) { return (candidate, version) }
        }
        let shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let output = await system.run(shell, ["-ilc", "command -v node"], timeout: Self.shellTimeout)
        // A login shell may print other lines first; the path is the last absolute one.
        guard let found = output?.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { $0.hasPrefix("/") }),
              !Self.nodeCandidates.contains(found), let version = await supportedVersion(found) else { return nil }
        return (found, version)
    }

    /// `node --version` when it is at least `minimumNode`, such as `v22.13.0`.
    func supportedVersion(_ path: String) async -> String? {
        guard system.isExecutable(path),
              let version = await system.run(path, ["--version"], timeout: Self.shellTimeout)?.trimmingCharacters(in: .whitespacesAndNewlines),
              version.hasPrefix("v") else { return nil }
        let parts = version.dropFirst().split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2, (parts[0], parts[1]) >= Self.minimumNode else { return nil }
        return version
    }

    public func findCLI() -> Result<(String, Runtime.CLISource), RuntimeProblem> {
        if let override = environment["SUBSET_TIMER_CLI_PATH"], !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return system.fileExists(path) ? .success((path, .override)) : .failure(.overrideMissing(path))
        }
        let bundled = ((resources ?? "") as NSString).appendingPathComponent("timer-cli/dist/cli.mjs")
        return resources != nil && system.fileExists(bundled) ? .success((bundled, .bundled)) : .failure(.bundledMissing(bundled))
    }
}

/// The real system: the file system and child processes.
public struct ProcessRuntimeSystem: RuntimeSystem {
    public init() {}

    public func isExecutable(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }

    public func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let once = Once()
            do {
                try process.run()
            } catch {
                once.run { continuation.resume(returning: nil) }
                return
            }
            // Read while it runs, so output larger than the pipe's buffer cannot block it.
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                once.run { continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run {
                    process.terminate()
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
