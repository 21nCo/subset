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

    /// The first Node.js \(minimumMajorVersion)+ in the common install locations, then in the user's login shell
    /// (covers nvm, fnm, and similar managers). An older Node in one place does not hide a newer one elsewhere.
    static func find() async -> String? {
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] {
            if await isSupported(candidate) { return candidate }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let output = await run(shell, ["-ilc", "command -v node"], timeout: 5)
        let fromShell = output?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        if let fromShell, await isSupported(fromShell) { return fromShell }
        return nil
    }

    /// Whether `path` is an executable Node.js whose major version is at least `minimumMajorVersion`.
    static func isSupported(_ path: String) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let version = await run(path, ["--version"], timeout: 5)?.trimmingCharacters(in: .whitespacesAndNewlines),
              version.hasPrefix("v"),
              let major = Int(version.dropFirst().split(separator: ".").first ?? "") else { return false }
        return major >= minimumMajorVersion
    }

    /// Runs a short command and returns its stdout, or nil if it could not start or did not finish in time.
    /// The process is terminated after `timeout` seconds (a slow login shell must not block readiness). One second
    /// later the caller gets nil and reading stops, even if a descendant that inherited stdout keeps the pipe open.
    /// Reads never block a thread, so a timed-out run leaves no worker behind.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 20) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let run = ShortRun(continuation, reader: output.fileHandleForReading)
            process.terminationHandler = { _ in run.markExited() }
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { run.markEndOfFile() } else { run.append(chunk) }
            }
            do {
                try process.run()
            } catch {
                run.finish(nil)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { run.finish(nil) }
            }
        }
    }

    /// The state of one `run`: output so far, and whether stdout reached EOF and the process exited. It resumes
    /// the caller once, with the output when both happened or with nil on timeout, and then stops reading.
    private final class ShortRun: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        private let reader: FileHandle
        private var data = Data()
        private var reachedEndOfFile = false
        private var exited = false

        init(_ continuation: CheckedContinuation<String?, Never>, reader: FileHandle) {
            self.continuation = continuation
            self.reader = reader
        }

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func markEndOfFile() {
            lock.lock()
            reachedEndOfFile = true
            lock.unlock()
            finishIfComplete()
        }

        func markExited() {
            lock.lock()
            exited = true
            lock.unlock()
            finishIfComplete()
        }

        private func finishIfComplete() {
            lock.lock()
            let complete = reachedEndOfFile && exited
            let text = String(data: data, encoding: .utf8)
            lock.unlock()
            if complete { finish(text) }
        }

        func finish(_ value: String?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            // Not closed here: a handler call already in flight may still read, and reading a closed handle
            // raises. The handle closes its descriptor when the last reference to it is released.
            reader.readabilityHandler = nil
            pending.resume(returning: value)
        }
    }

    static func environment(forNode nodePath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let nodeDirectory = URL(fileURLWithPath: nodePath).deletingLastPathComponent().path
        environment["PATH"] = nodeDirectory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }
}
