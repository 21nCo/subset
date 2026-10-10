import AppKit
import Foundation
import OSLog

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

/// What the app needs before it can send the bot: Node.js, the Minutes CLI, and a passing `doctor`.
struct MinutesReadiness: Equatable {
    var nodePath: String?
    var cli: MinutesCLILocation?
    var doctor: MinutesDoctorReport?
    /// Why `doctor` produced no report (the CLI could not run, or printed something unexpected).
    var doctorError: String?

    var isReady: Bool {
        nodePath != nil && cli != nil && (doctor?.ok ?? false)
    }

    func check(_ id: String) -> MinutesDoctorReport.Check? {
        doctor?.checks.first { $0.id == id }
    }
}

/// A first-pass check of the link for the form: an `https` link on a Google Meet or Zoom host.
/// The CLI (`parseMeetingLink` in `@subset/minutes`) is the authority and rejects anything else with a
/// structured `invalid_link` error, which the app shows like any other failure.
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

/// Runs the shared Minutes CLI (`subset-minutes`, package `@subset.dev/minutes`) as a child process.
/// `join --json` streams the versioned NDJSON contract from `@subset/minutes`; this class turns those
/// events into UI state. The app implements no meeting logic of its own.
@MainActor
final class MinutesController: ObservableObject {
    @Published private(set) var phase: BotPhase = .idle
    @Published private(set) var logs: [BotLogEntry] = []
    @Published private(set) var recordingPath: String?
    @Published private(set) var joinedAt: Date?
    @Published private(set) var lastErrorCode: String?
    @Published private(set) var readiness = MinutesReadiness()
    @Published private(set) var isCheckingReadiness = false

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stopRequested = false
    /// The CLI's last `error` event; its `ended` event (reason `failed`) follows.
    private var lastErrorMessage: String?
    /// A folder chosen while a readiness check was running; checked again when it finishes.
    private var pendingReadinessDirectory: String?
    private let logger = Logger(subsystem: "dev.subset.minutes", category: "cli")

    /// The bot's Chrome profile. Matches the CLI default on macOS (`~/Library/Application Support/Subset Minutes`)
    /// and is passed explicitly so the app and a terminal session share one signed-in profile.
    static let botProfileDirectory: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Subset Minutes", isDirectory: true)
            .appendingPathComponent("google-meet-bot-profile", isDirectory: true)
            .path
    }()

    var isRunning: Bool { process != nil }

    // MARK: Readiness

    /// Finds Node.js and the CLI, then runs `subset-minutes doctor --json` for the Chrome, profile, and folder checks.
    func refreshReadiness(outputDirectory: String) {
        guard !isCheckingReadiness else {
            // Do not drop the request: the checklist must describe the folder that will be used.
            pendingReadinessDirectory = outputDirectory
            return
        }
        isCheckingReadiness = true
        Task { @MainActor in
            var next = MinutesReadiness()
            next.nodePath = await NodeLocator.find()
            next.cli = MinutesCLILocation.resolve()
            if let cli = next.cli {
                logger.info("Using the Minutes CLI at \(cli.scriptPath, privacy: .public) (\(cli.source.rawValue, privacy: .public))")
            } else {
                logger.error("The Minutes CLI was not found")
            }
            if let node = next.nodePath, let cli = next.cli {
                let output = await NodeLocator.run(
                    node,
                    [cli.scriptPath, "doctor", "--json", "--out", outputDirectory, "--profile", Self.botProfileDirectory],
                    environment: NodeLocator.environment(forNode: node)
                )
                if let output, let report = MinutesDoctorReport.decode(Data(output.utf8)) {
                    next.doctor = report
                    logger.info("doctor --json: ok=\(report.ok, privacy: .public)")
                } else {
                    next.doctorError = "The Minutes CLI did not return a doctor report. Check that Node.js \(NodeLocator.minimumMajorVersion)+ is installed and the CLI is built."
                    logger.error("doctor --json returned no valid report")
                }
            }
            readiness = next
            isCheckingReadiness = false
            if let pending = pendingReadinessDirectory {
                pendingReadinessDirectory = nil
                refreshReadiness(outputDirectory: pending)
            }
        }
    }

    // MARK: Operations

    func start(link: MeetingLink, displayName: String, recordingDirectory: String) {
        guard process == nil else { return }
        guard readiness.isReady, let nodePath = readiness.nodePath, let cli = readiness.cli else {
            fail("Minutes is not ready. Complete the setup checklist first.")
            return
        }

        logs.removeAll()
        recordingPath = nil
        joinedAt = nil
        lastErrorCode = nil
        lastErrorMessage = nil
        stopRequested = false
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()

        // The link goes to the CLI on stdin, not as an argument: arguments are visible to every process
        // (`ps`), and a Zoom link can carry its passcode. It is never logged here; the CLI reports only a
        // redacted form.
        var arguments = [cli.scriptPath, "join", "--link-from-stdin", "--json", "--stop-on-stdin-close",
                         "--profile", Self.botProfileDirectory]
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { arguments += ["--name", name] }
        if !recordingDirectory.isEmpty { arguments += ["--out", recordingDirectory] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = arguments
        process.environment = NodeLocator.environment(forNode: nodePath)

        // stdin stays open while the app runs. If the app quits or crashes, it closes and the CLI
        // stops and finalizes the recording (--stop-on-stdin-close).
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Finalize only after the process exited and both pipes reached EOF, so every chunk of output is
        // handled first. Each reader delivers its chunks to the main queue in the order it read them.
        let finished = DispatchGroup()
        finished.enter()
        process.terminationHandler = { _ in finished.leave() }

        do {
            try process.run()
        } catch {
            finished.leave()
            fail("Could not start the Minutes CLI: \(error.localizedDescription)")
            return
        }
        self.process = process
        self.stdinPipe = stdinPipe
        Self.readUntilEndOfFile(stdoutPipe.fileHandleForReading, group: finished) { [weak self] data in self?.consumeStdout(data) }
        Self.readUntilEndOfFile(stderrPipe.fileHandleForReading, group: finished) { [weak self] data in self?.consumeStderr(data) }
        finished.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.consumeStderr(Data("\n".utf8))
                self?.handleTermination(status: process.terminationStatus)
            }
        }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((link.url.absoluteString + "\n").utf8))
        phase = .launching
        logger.info("Spawned subset-minutes join (pid \(process.processIdentifier, privacy: .public))")
        appendLog("Started subset-minutes for \(link.platformName) (PID \(process.processIdentifier)).")
    }

    /// Reads `handle` on a background queue until EOF and hands each chunk to `deliver` on the main queue, in order.
    private nonisolated static func readUntilEndOfFile(_ handle: FileHandle, group: DispatchGroup,
                                                       deliver: @escaping @MainActor @Sendable (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while case let data = handle.availableData, !data.isEmpty {
                DispatchQueue.main.async { MainActor.assumeIsolated { deliver(data) } }
            }
            group.leave()
        }
    }

    /// Asks the CLI to leave (SIGINT) so it finalizes the recording; forces it to stop after 15 seconds.
    func stop() {
        guard let process, process.isRunning else { return }
        stopRequested = true
        phase = .stopping
        process.interrupt()
        appendLog("Asked the bot to leave the meeting.")
        // Capture this process: a new session started in the meantime must not be terminated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, process] in
            guard let self, process.isRunning else { return }
            process.terminate()
            self.appendLog("The bot did not exit in time and was terminated.", isError: true)
        }
    }

    /// Runs `subset-minutes sign-in`, which opens Chrome with the bot's profile at accounts.google.com.
    func openBotSignIn() {
        guard let node = readiness.nodePath, let cli = readiness.cli else {
            fail("Node.js and the Minutes CLI are needed to open the sign-in window.")
            return
        }
        Task { @MainActor in
            let output = await NodeLocator.run(node, [cli.scriptPath, "sign-in", "--profile", Self.botProfileDirectory],
                                               environment: NodeLocator.environment(forNode: node))
            if let output, !output.isEmpty {
                for line in output.split(whereSeparator: \.isNewline) { appendLog(String(line)) }
            } else {
                fail("Could not open the bot sign-in window.")
            }
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

    private func handleLine(_ line: String) {
        switch MinutesEvent.decode(line: line) {
        case .text:
            appendLog(line)
        case .unsupported(let message):
            appendLog(message, isError: true)
            logger.error("Unsupported CLI output: \(message, privacy: .public)")
        case .event(let event):
            handle(event)
        }
    }

    private func handle(_ event: MinutesEvent) {
        switch event.type {
        case .started:
            appendLog("Sending \"\(event.displayName ?? "")\" to \(event.meeting ?? "the meeting").")
        case .state:
            switch event.state {
            case "launching", "joining":
                if phase != .stopping { phase = .launching }
            case "in_meeting":
                // A join that completes after Stop must not re-enable Leave and Stop.
                guard !stopRequested else { break }
                phase = .inMeeting
                joinedAt = .now
                appendLog("Joined the meeting.")
            case "stopping":
                phase = .stopping
            default:
                break // ended and failed arrive with the ended event.
            }
        case .status:
            appendLog(event.message ?? "")
        case .recording:
            recordingPath = event.path
            appendLog("Writing audio to \(event.path ?? "an unknown file").")
        case .error:
            // The session is still finishing (the recording is being closed); the ended event follows.
            lastErrorCode = event.code
            lastErrorMessage = event.message
            logger.error("CLI error \(event.code ?? "unknown", privacy: .public)")
            appendLog("[\(event.code ?? "error")] \(event.message ?? "Unknown error.")", isError: true)
        case .ended:
            recordingPath = event.path
            let reason = event.reason ?? "ended"
            if reason == "failed" {
                phase = .failed(lastErrorMessage ?? "The bot stopped with an error. See Details for its log.")
            } else {
                phase = .ended(reason)
            }
            appendLog("Session ended (\(reason))\(event.bytes.map { ", \($0) bytes of audio" } ?? "").")
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        stdinPipe = nil
        appendLog("subset-minutes exited with status \(status).", isError: status != 0 && !stopRequested)
        switch phase {
        case .failed:
            break
        case .ended where status == 0:
            break
        case .ended:
            // The CLI said it ended but then exited abnormally (for example the 15-second forced stop).
            phase = .failed("subset-minutes exited with status \(status) while finishing. The recording may be incomplete.")
        default:
            if status == 0 {
                phase = .ended(stopRequested ? "stopped" : "exited")
            } else if stopRequested {
                phase = .failed("The bot was stopped, but subset-minutes exited with status \(status) before finishing. The recording may be incomplete.")
            } else {
                phase = .failed("subset-minutes exited with status \(status). See Details for its log.")
            }
        }
    }

    /// Reports a failure in the app itself. While a session runs, the session's own state wins.
    private func fail(_ message: String) {
        if !phase.isActive { phase = .failed(message) }
        appendLog(message, isError: true)
    }

    private func consumeStderr(_ data: Data) {
        stderrBuffer.append(data)
        while let newline = stderrBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stderrBuffer[stderrBuffer.startIndex..<newline]
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                appendLog(line, isError: true)
            }
        }
    }

    private func appendLog(_ text: String, isError: Bool = false) {
        logs.append(BotLogEntry(date: .now, text: text, isError: isError))
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }
}

/// Reads the URL of the front tab in a running browser, only when the user asks.
enum BrowserTabReader {
    private static let scripts: [(bundleID: String, source: String)] = [
        ("com.google.Chrome", "tell application id \"com.google.Chrome\" to if (count of windows) > 0 then return URL of active tab of front window"),
        ("com.apple.Safari", "tell application id \"com.apple.Safari\" to if (count of documents) > 0 then return URL of front document")
    ]

    /// Runs each script with `osascript` off the main thread, so a slow browser or the first Automation
    /// consent prompt does not freeze the window.
    static func frontMeetingLink() async -> MeetingLink? {
        for script in scripts where !NSRunningApplication.runningApplications(withBundleIdentifier: script.bundleID).isEmpty {
            let output = await NodeLocator.run("/usr/bin/osascript", ["-e", script.source], timeout: 30)
            if let value = output?.trimmingCharacters(in: .whitespacesAndNewlines), let link = MeetingLink(value) {
                return link
            }
        }
        return nil
    }
}
