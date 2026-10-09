import Foundation

/// The app's view of the shared `@subset/minutes` contract. The CLI (`subset-minutes`) owns every
/// operation; the app spawns it with `--json` and decodes its output. Keep `supportedContractVersion`
/// equal to `MINUTES_CONTRACT_VERSION` in `packages/minutes/src/contract.ts`
/// (`scripts/check-workspaces.mjs` enforces this).
enum MinutesContract {
    static let supportedContractVersion = 1
}

/// One NDJSON line from `subset-minutes join --json`.
struct MinutesEvent: Decodable, Equatable {
    enum Kind: String, Decodable {
        case started, state, status, recording, error, ended
    }

    let v: Int
    let at: String
    let session: String?
    let type: Kind
    // Per-type fields; the CLI validates the full shape before emitting.
    let platform: String?
    let meeting: String?
    let displayName: String?
    let outputDirectory: String?
    let state: String?
    let message: String?
    let path: String?
    let code: String?
    let reason: String?
    let bytes: Int?

    enum DecodeResult: Equatable {
        case event(MinutesEvent)
        /// Valid JSON that is not a supported Minutes event (unknown version or type).
        case unsupported(String)
        /// Not JSON: plain output, shown in the log as is.
        case text
    }

    static func decode(line: String) -> DecodeResult {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .text
        }
        guard let version = object["v"] as? Int, version == MinutesContract.supportedContractVersion else {
            return .unsupported("Minutes CLI contract version \(object["v"].map { "\($0)" } ?? "missing") is not supported by this app (expects \(MinutesContract.supportedContractVersion)). Update the app and the CLI together.")
        }
        guard let event = try? JSONDecoder().decode(MinutesEvent.self, from: data) else {
            return .unsupported("Unrecognized Minutes event: \(object["type"] ?? "no type").")
        }
        return .event(event)
    }
}

/// `subset-minutes doctor --json`.
struct MinutesDoctorReport: Decodable, Equatable {
    struct Check: Decodable, Equatable, Identifiable {
        let id: String
        let ok: Bool
        let required: Bool
        let detail: String
        let fix: String?
    }

    let v: Int
    let kind: String
    let ok: Bool
    let chromePath: String?
    let profileDirectory: String
    let outputDirectory: String
    let checks: [Check]

    static func decode(_ data: Data) -> MinutesDoctorReport? {
        guard let report = try? JSONDecoder().decode(MinutesDoctorReport.self, from: data),
              report.v == MinutesContract.supportedContractVersion,
              report.kind == "minutes.doctor" else { return nil }
        return report
    }
}

/// Where the app finds the CLI. See native/minutes/README.md ("How the app runs the CLI").
struct MinutesCLILocation: Equatable {
    enum Source: String {
        case override = "MINUTES_CLI_PATH"
        case bundled = "bundled in the app"
        case repository = "repository build"
    }

    let scriptPath: String
    let source: Source

    /// 1. `MINUTES_CLI_PATH` (a `cli.mjs`), 2. the copy embedded in `Minutes.app/Contents/Resources/minutes-cli`,
    /// 3. a development build at `packages/minutes-cli/dist/cli.mjs` in this repository.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        bundle: Bundle = .main,
                        fileManager: FileManager = .default) -> MinutesCLILocation? {
        if let override = environment["MINUTES_CLI_PATH"], !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fileManager.fileExists(atPath: path) ? MinutesCLILocation(scriptPath: path, source: .override) : nil
        }
        if let resources = bundle.resourceURL {
            let bundled = resources.appendingPathComponent("minutes-cli/dist/cli.mjs").path
            if fileManager.fileExists(atPath: bundled) { return MinutesCLILocation(scriptPath: bundled, source: .bundled) }
        }
        let repository = repositoryScriptPath
        if fileManager.fileExists(atPath: repository) { return MinutesCLILocation(scriptPath: repository, source: .repository) }
        return nil
    }

    /// `native/minutes/MacApp/` → repository root → `packages/minutes-cli/dist/cli.mjs`. Only meaningful for a local build.
    static var repositoryScriptPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("packages/minutes-cli/dist/cli.mjs")
            .path
    }
}

enum NodeLocator {
    static let minimumMajorVersion = 22

    /// Common install locations, then the user's login shell (covers nvm, fnm, and similar managers).
    static func find() async -> String? {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let output = await run("/bin/zsh", ["-ilc", "command -v node"], timeout: 5)
        return output?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a short command and returns its stdout, or nil if it could not start.
    /// The process is terminated after `timeout` seconds (a slow login shell must not block readiness).
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 20) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }.value
    }

    static func environment(forNode nodePath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let nodeDirectory = URL(fileURLWithPath: nodePath).deletingLastPathComponent().path
        environment["PATH"] = nodeDirectory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }
}
