import AppKit
import Foundation

/// One line of the bot's output, shown in the details log.
struct BotLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
    let isError: Bool

    var formattedTime: String {
        date.formatted(date: .omitted, time: .standard)
    }
}

/// The user-visible lifecycle of one bot session.
enum BotPhase: Equatable {
    case idle
    case launching
    case inMeeting
    case stopping
    case ended(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .launching: return "Joining meeting…"
        case .inMeeting: return "In meeting, recording audio"
        case .stopping: return "Leaving meeting…"
        case .ended: return "Recording finished"
        case .failed: return "Bot stopped with an error"
        }
    }

    var isActive: Bool {
        switch self {
        case .launching, .inMeeting, .stopping: return true
        default: return false
        }
    }
}

/// What the local bot runtime needs before it can start.
struct BotRuntimeReadiness: Equatable {
    var nodePath: String?
    var chromePath: String?
    var runtimeDirectory: String
    var hasSources: Bool
    var hasDependencies: Bool

    var isReady: Bool {
        nodePath != nil && chromePath != nil && hasSources && hasDependencies
    }
}

/// Supported meeting links. Anything else is rejected before the bot is launched.
enum MeetingLink {
    case googleMeet(URL)
    case zoom(URL)

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return nil }

        if host == "meet.google.com", url.path.count > 1 {
            self = .googleMeet(url)
        } else if host == "zoom.us" || host.hasSuffix(".zoom.us"), url.path.count > 1 {
            self = .zoom(url)
        } else {
            return nil
        }
    }

    var url: URL {
        switch self {
        case .googleMeet(let url), .zoom(let url): return url
        }
    }

    var platformID: String {
        switch self {
        case .googleMeet: return "google-meet"
        case .zoom: return "zoom"
        }
    }

    var platformName: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .zoom: return "Zoom (web client)"
        }
    }
}

/// Launches and supervises the local Playwright bot in `BotRuntime/` as a child process.
/// The bot writes one JSON event per line on stdout (see `BotRuntime/src/status.ts`).
@MainActor
final class BotRuntimeController: ObservableObject {
    @Published private(set) var phase: BotPhase = .idle
    @Published private(set) var logs: [BotLogEntry] = []
    @Published private(set) var recordingPath: String?
    @Published private(set) var joinedAt: Date?
    @Published private(set) var readiness: BotRuntimeReadiness
    @Published private(set) var isCheckingReadiness = false

    private var process: Process?
    private var stdoutBuffer = Data()
    private var stopRequested = false

    static let botProfileDirectory: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Subset Minutes", isDirectory: true)
            .appendingPathComponent("google-meet-bot-profile", isDirectory: true)
            .path
    }()

    init() {
        let directory = Self.resolveRuntimeDirectory()
        readiness = BotRuntimeReadiness(
            nodePath: nil,
            chromePath: Self.findChromePath(),
            runtimeDirectory: directory,
            hasSources: FileManager.default.fileExists(atPath: directory + "/src/index.ts"),
            hasDependencies: FileManager.default.fileExists(atPath: directory + "/node_modules/tsx")
        )
    }

    var isRunning: Bool { process != nil }

    // MARK: Readiness

    func refreshReadiness() {
        guard !isCheckingReadiness else { return }
        isCheckingReadiness = true
        let directory = Self.resolveRuntimeDirectory()
        Task { @MainActor in
            let nodePath = await Self.findNodePath()
            readiness = BotRuntimeReadiness(
                nodePath: nodePath,
                chromePath: Self.findChromePath(),
                runtimeDirectory: directory,
                hasSources: FileManager.default.fileExists(atPath: directory + "/src/index.ts"),
                hasDependencies: FileManager.default.fileExists(atPath: directory + "/node_modules/tsx")
            )
            isCheckingReadiness = false
        }
    }

    // MARK: Operations

    func start(link: MeetingLink, displayName: String, recordingDirectory: String) {
        guard process == nil else { return }
        guard readiness.isReady, let nodePath = readiness.nodePath else {
            fail("The bot runtime is not ready. Complete the setup checklist first.")
            return
        }

        logs.removeAll()
        recordingPath = nil
        joinedAt = nil
        stopRequested = false
        stdoutBuffer.removeAll()

        var arguments = ["--import", "tsx", "src/index.ts", link.url.absoluteString, "--platform=\(link.platformID)"]
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { arguments.append("--name=\(name)") }
        if !recordingDirectory.isEmpty { arguments.append("--recording-dir=\(recordingDirectory)") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: readiness.runtimeDirectory)
        var environment = ProcessInfo.processInfo.environment
        let nodeDirectory = URL(fileURLWithPath: nodePath).deletingLastPathComponent().path
        environment["PATH"] = nodeDirectory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["MEETING_BOT_PROFILE_DIR"] = Self.botProfileDirectory
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consumeStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for line in text.split(whereSeparator: \.isNewline) {
                    self?.appendLog(String(line), isError: true)
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in self?.handleTermination(status: status) }
        }

        do {
            try process.run()
            self.process = process
            phase = .launching
            appendLog("Started bot for \(link.platformName) (PID \(process.processIdentifier)).")
        } catch {
            fail("Could not start the bot: \(error.localizedDescription)")
        }
    }

    /// Asks the bot to leave (SIGINT) and forces it to stop after five seconds.
    func stop() {
        guard let process, process.isRunning else { return }
        stopRequested = true
        phase = .stopping
        process.interrupt()
        appendLog("Asked the bot to leave the meeting.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let running = self.process, running.isRunning else { return }
            running.terminate()
            self.appendLog("The bot did not exit in time and was terminated.", isError: true)
        }
    }

    /// Opens Chrome with the bot's dedicated profile so the user can sign in to a Google account once.
    func openBotSignIn() {
        guard let chromePath = Self.findChromePath() else {
            fail("Google Chrome was not found. Install Chrome to set up the bot's sign-in.")
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: Self.botProfileDirectory, withIntermediateDirectories: true)
            let chrome = Process()
            chrome.executableURL = URL(fileURLWithPath: chromePath)
            chrome.arguments = [
                "--user-data-dir=\(Self.botProfileDirectory)",
                "--no-first-run",
                "--new-window",
                "https://accounts.google.com"
            ]
            try chrome.run()
            appendLog("Opened Chrome with the bot profile. Sign in with the bot's Google account, then quit that Chrome window before starting the bot.")
        } catch {
            fail("Could not open the bot sign-in window: \(error.localizedDescription)")
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: Event handling

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespaces), !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private struct BotEvent: Decodable {
        let type: String
        let message: String?
        let platform: String?
        let url: String?
        let path: String?
        let reason: String?
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(BotEvent.self, from: data) else {
            appendLog(line)
            return
        }

        switch event.type {
        case "status":
            appendLog(event.message ?? "")
        case "recording":
            recordingPath = event.path
            appendLog("Writing audio to \(event.path ?? "an unknown file").")
        case "joined":
            phase = .inMeeting
            joinedAt = .now
            appendLog("Joined \(event.platform ?? "the meeting").")
        case "error":
            fail(event.message ?? "Unknown bot error.")
        case "ended":
            phase = .ended(event.reason ?? "ended")
            appendLog("Session ended (\(event.reason ?? "ended")).")
        default:
            appendLog(line)
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        appendLog("Bot process exited with status \(status).", isError: status != 0 && !stopRequested)
        switch phase {
        case .failed, .ended:
            break
        default:
            if status == 0 || stopRequested {
                phase = .ended(stopRequested ? "stopped" : "exited")
            } else {
                phase = .failed("The bot exited with status \(status). See Details for its log.")
            }
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        appendLog(message, isError: true)
    }

    private func appendLog(_ text: String, isError: Bool = false) {
        logs.append(BotLogEntry(date: .now, text: text, isError: isError))
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    // MARK: Discovery

    /// `MINUTES_BOT_RUNTIME_DIR` overrides the location. Otherwise a local build uses the
    /// `BotRuntime/` directory next to this source file.
    private static func resolveRuntimeDirectory() -> String {
        if let override = ProcessInfo.processInfo.environment["MINUTES_BOT_RUNTIME_DIR"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BotRuntime", isDirectory: true)
            .path
    }

    private static func findChromePath() -> String? {
        [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            NSHomeDirectory() + "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium"
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Looks in common install locations, then asks the user's login shell (covers nvm and similar managers).
    private static func findNodePath() async -> String? {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        return await Task.detached(priority: .utility) { () -> String? in
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-ilc", "command -v node"]
            let output = Pipe()
            shell.standardOutput = output
            shell.standardError = FileHandle.nullDevice
            do {
                try shell.run()
            } catch {
                return nil
            }
            shell.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        }.value
    }
}

/// Reads the URL of the front tab in a running browser, only when the user asks.
enum BrowserTabReader {
    private static let scripts: [(bundleID: String, source: String)] = [
        ("com.google.Chrome", "tell application id \"com.google.Chrome\" to if (count of windows) > 0 then return URL of active tab of front window"),
        ("com.apple.Safari", "tell application id \"com.apple.Safari\" to if (count of documents) > 0 then return URL of front document")
    ]

    @MainActor
    static func frontMeetingLink() -> MeetingLink? {
        for script in scripts where !NSRunningApplication.runningApplications(withBundleIdentifier: script.bundleID).isEmpty {
            var error: NSDictionary?
            let result = NSAppleScript(source: script.source)?.executeAndReturnError(&error)
            if let value = result?.stringValue, let link = MeetingLink(value) {
                return link
            }
        }
        return nil
    }
}
