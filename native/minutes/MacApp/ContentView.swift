import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bot: MinutesController

    @AppStorage("displayName") private var displayName = "Minutes Notetaker"
    @AppStorage("recordingDirectory") private var recordingDirectory = ContentView.defaultRecordingDirectory
    @State private var meetingURL = ""
    @State private var isChoosingSaveDirectory = false
    @State private var tabLookupMessage: String?
    @State private var showsDetails = false

    static let defaultRecordingDirectory: String = (
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Minutes Recordings").path
        ?? NSHomeDirectory() + "/Documents/Minutes Recordings"
    )

    private var meetingLink: MeetingLink? { MeetingLink(meetingURL) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            configPanel
                .frame(width: 340)
            Divider()
            sessionPanel
        }
        .onAppear { bot.refreshReadiness(outputDirectory: recordingDirectory) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !bot.isRunning { bot.refreshReadiness(outputDirectory: recordingDirectory) }
        }
        // A stale "no tab found" message must not stay after the link is typed or pasted.
        .onChange(of: meetingURL) { _, _ in
            if tabLookupMessage != nil, meetingLink != nil { tabLookupMessage = nil }
        }
        .fileImporter(isPresented: $isChoosingSaveDirectory, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                recordingDirectory = url.path
                bot.refreshReadiness(outputDirectory: url.path)
            }
        }
    }

    // MARK: - Left: setup and meeting

    private var configPanel: some View {
        Form {
            Section("Meeting") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Meeting link", text: $meetingURL, prompt: Text("https://meet.google.com/abc-defg-hij"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .disabled(bot.isRunning)
                        .onSubmit(startIfPossible)
                        .accessibilityLabel("Meeting link")

                    linkValidationLabel

                    HStack {
                        Button("Paste") { pasteLink() }
                            .disabled(bot.isRunning)
                        Button("Use Current Tab") { useCurrentTab() }
                            .disabled(bot.isRunning)
                            .help("Read the Google Meet or Zoom link from the front Chrome or Safari tab")
                    }
                    .controlSize(.small)

                    if let tabLookupMessage {
                        Text(tabLookupMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Bot name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(bot.isRunning)
                    .accessibilityLabel("Name the bot uses in the meeting")

                Label(nameDisclosure, systemImage: "person.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Save audio to") {
                HStack {
                    Text(URL(fileURLWithPath: recordingDirectory).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(recordingDirectory)
                    Spacer()
                    Button("Choose…") { isChoosingSaveDirectory = true }
                        .disabled(bot.isRunning)
                    Button("Open") { openRecordingDirectory() }
                }
                .controlSize(.small)
            }

            setupSection

            Section {
                startStopButton
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var linkValidationLabel: some View {
        if meetingURL.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Paste a Google Meet or Zoom link.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let meetingLink {
            Label(meetingLink.platformName, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Not a Google Meet or Zoom https link.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var setupSection: some View {
        let readiness = bot.readiness
        return Section {
            SetupRow(
                title: "Node.js",
                detail: readiness.nodePath ?? "Not found. Install Node.js \(NodeLocator.minimumMajorVersion) or later (for example `brew install node`).",
                isDone: readiness.nodePath != nil
            )
            SetupRow(
                title: "Minutes CLI",
                detail: cliDetail(readiness),
                // The CLI is only proven to run once doctor ran, which needs Node.js.
                isDone: readiness.cli != nil && readiness.nodePath != nil && readiness.doctorError == nil
            )
            if let doctor = readiness.doctor {
                ForEach(doctor.checks.filter { $0.id != "node" || !$0.ok }) { check in
                    SetupRow(
                        title: Self.checkTitles[check.id] ?? check.id,
                        detail: [check.detail, check.fix].compactMap { $0 }.joined(separator: " "),
                        isDone: check.ok,
                        isOptional: !check.required
                    )
                }
            }
            HStack {
                Button("Set Up Google Sign-In…") { bot.openBotSignIn() }
                    // A running bot is using this profile.
                    .disabled(readiness.cli == nil || readiness.nodePath == nil || bot.isRunning)
                    .help("Open Chrome with the bot's own profile so it can join Meet as a signed-in user instead of waiting as a guest")
                Spacer()
                Button(bot.isCheckingReadiness ? "Checking…" : "Check Again") { bot.refreshReadiness(outputDirectory: recordingDirectory) }
                    .disabled(bot.isCheckingReadiness || bot.isRunning)
            }
            .controlSize(.small)
        } header: {
            Text("Setup")
        }
    }

    private static let checkTitles = [
        "node": "Node.js version",
        "chrome": "Google Chrome",
        "profile": "Bot Google sign-in (optional)",
        "profile_lock": "Bot profile not in use",
        "output_directory": "Output folder"
    ]

    private func cliDetail(_ readiness: MinutesReadiness) -> String {
        guard let cli = readiness.cli else {
            return "subset-minutes not found. Build it with `npm ci && npm run build` at the repository root, or set MINUTES_CLI_PATH."
        }
        if let error = readiness.doctorError { return error }
        return "\(cli.source.rawValue): \(cli.scriptPath)"
    }

    private var startStopButton: some View {
        Group {
            if bot.isRunning {
                Button(role: .destructive) {
                    bot.stop()
                } label: {
                    Label("Leave and Stop", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
                .help("Ask the bot to leave the meeting and finish the file (⌘.)")
                .disabled(bot.phase == .stopping)
            } else {
                Button(action: startIfPossible) {
                    Label("Send Bot to Meeting", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help(startHelp)
                .disabled(meetingLink == nil || !bot.readiness.isReady)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var startHelp: String {
        if !bot.readiness.isReady { return "Complete the setup checklist first" }
        if meetingLink == nil { return "Enter a Google Meet or Zoom link" }
        return "Send the bot to the meeting (⌘↩)"
    }

    // MARK: - Right: session

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusCard
            outputCard
            DisclosureGroup(isExpanded: $showsDetails) {
                logList
            } label: {
                HStack {
                    Text("Details")
                        .font(.headline)
                    Text("\(bot.logs.count) log lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !bot.logs.isEmpty {
                        Button("Copy Log") { copyLog() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Button("Clear") { bot.clearLogs() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(bot.isRunning)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: statusSymbol)
                .font(.system(size: 28))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(bot.phase.title)
                    .font(.title3.weight(.semibold))
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if bot.phase == .inMeeting, let joinedAt = bot.joinedAt {
                Text(joinedAt, style: .timer)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Time in meeting")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch bot.phase {
        case .idle: return "person.crop.circle.badge.questionmark"
        case .launching, .stopping: return "hourglass"
        case .inMeeting: return "record.circle"
        case .ended: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch bot.phase {
        case .inMeeting: return .red
        case .ended: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var statusDetail: String {
        switch bot.phase {
        case .idle:
            return "Paste a meeting link and send the bot. Minutes runs the subset-minutes CLI, which joins in a Chrome window, mutes itself, and records the other participants' audio to a WebM file."
        case .launching:
            return "Opening Chrome and joining. If the meeting has a waiting room, admit the bot."
        case .inMeeting:
            return "Recording until the meeting ends or you stop the bot."
        case .stopping:
            return "Finishing the audio file."
        case .ended(let reason):
            let headline = reason == "meeting_ended" ? "The meeting ended." : "The bot left the meeting."
            return headline + (bot.recordingPath == nil ? " No audio file was produced." : " The audio file is below.")
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var outputCard: some View {
        if let path = bot.recordingPath {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("WebM/Opus audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Audio file \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(bot.logs) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.formattedTime)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(entry.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(entry.isError ? Color.red : Color.primary)
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 160, maxHeight: 320)
            // The log is capped, so its count stops changing; follow the newest entry instead.
            .onChange(of: bot.logs.last?.id) { _, _ in
                if let last = bot.logs.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Actions

    private func startIfPossible() {
        guard let meetingLink, bot.readiness.isReady, !bot.isRunning else { return }
        showsDetails = false
        bot.start(link: meetingLink, displayName: displayName, recordingDirectory: recordingDirectory)
    }

    private func pasteLink() {
        if let text = NSPasteboard.general.string(forType: .string) {
            meetingURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func useCurrentTab() {
        tabLookupMessage = "Reading the front browser tab…"
        Task { @MainActor in
            if let link = await BrowserTabReader.frontMeetingLink() {
                meetingURL = link.url.absoluteString
                tabLookupMessage = nil
            } else {
                tabLookupMessage = "No Google Meet or Zoom tab was found in the front Chrome or Safari window, or Automation access was denied."
            }
        }
    }

    /// Signed-in Meet sessions show the bot's Google account name, not this field.
    private var nameDisclosure: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Minutes Notetaker" : trimmed
        return "Everyone in the meeting will see the bot join as “\(name)” (in Google Meet, as the bot's Google account name when it is signed in). Tell participants you are recording, and follow the recording rules that apply to you."
    }

    private func openRecordingDirectory() {
        try? FileManager.default.createDirectory(atPath: recordingDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: recordingDirectory))
    }

    private func copyLog() {
        let text = bot.logs.map { "\($0.formattedTime) \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct SetupRow: View {
    let title: String
    let detail: String
    let isDone: Bool
    var isOptional = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isDone ? "checkmark.circle.fill" : isOptional ? "info.circle" : "exclamationmark.circle")
                .foregroundStyle(isDone ? Color.green : isOptional ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(isDone ? "ready" : isOptional ? "optional" : "action needed"). \(detail)")
    }
}
