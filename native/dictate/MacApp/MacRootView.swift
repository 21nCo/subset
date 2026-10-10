import AppKit
import SwiftUI

struct MacRootView: View {
    @EnvironmentObject private var manager: DictationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            setupChecklist
            controls
            TranscriptCard(
                title: "Last transcript",
                text: transcriptText,
                emptyMessage: "Hold fn in any text field and speak. Release fn to insert the text where your cursor is.",
                tint: .green,
                onCopy: manager.copyableTranscript.isEmpty ? nil : { manager.copyLastTranscript() }
            )
            shortcutLegend
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { manager.refreshSetupStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Permission changes happen in System Settings, so re-check when the user comes back.
            manager.refreshSetupStatus()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dictate")
                .font(.title2.weight(.bold))

            Text("Speak into any app. Transcription runs locally with whisper.cpp; audio is not uploaded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(manager.transcriptState.statusMessage, systemImage: statusSymbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Status: \(manager.transcriptState.statusMessage)")
        }
    }

    private var statusSymbol: String {
        if manager.isFinalizing { return "ellipsis.circle" }
        return manager.transcriptState.isRecording ? "mic.fill" : "checkmark.circle"
    }

    // MARK: Setup

    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup")
                .font(.headline)

            SetupRow(
                title: "Microphone",
                detail: microphoneDetail,
                isDone: manager.microphonePermission == "Granted"
            ) {
                if manager.microphonePermission == "Undetermined" {
                    Button("Allow…") { manager.requestMicrophoneAccess() }
                } else {
                    Button("Open Settings") { manager.openPrivacySettings(.microphone) }
                }
            }

            SetupRow(
                title: "Accessibility",
                detail: manager.isAccessibilityTrusted
                    ? "Granted. Dictate can detect fn and insert text into the focused field."
                    : "Needed to detect the fn key in other apps and insert text where your cursor is.",
                isDone: manager.isAccessibilityTrusted
            ) {
                Button("Allow…") { manager.requestAccessibilityAccess() }
                Button("Open Settings") { manager.openPrivacySettings(.accessibility) }
            }

            SetupRow(
                title: "Speech model (\(manager.settings.whisperModelPreset.title))",
                detail: manager.localModelStatus,
                isDone: manager.isLocalModelReady
            ) {
                Button(manager.isPreparingLocalModel ? "Downloading…" : "Download") {
                    manager.prepareSelectedWhisperModel()
                }
                .disabled(manager.isPreparingLocalModel)
                Button("Show in Finder") { manager.revealWhisperModelsFolder() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var microphoneDetail: String {
        switch manager.microphonePermission {
        case "Granted": return "Granted."
        case "Denied": return "Denied. Turn on Dictate in System Settings > Privacy & Security > Microphone."
        default: return "Dictate asks for the microphone the first time you dictate."
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button(manager.transcriptState.isRecording ? "Stop Dictation" : "Start Dictation") {
                manager.toggleDictationFromUI()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(manager.isFinalizing)
            .help("Start or stop dictating into this window (⌘↩)")

            Button("Copy") {
                manager.copyLastTranscript()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(manager.copyableTranscript.isEmpty)
            .help("Copy the last transcript (⇧⌘C)")

            Button("Clear") {
                manager.clearTranscript()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("k", modifiers: .command)
            .help("Clear the transcript buffer (⌘K)")
        }
    }

    private var shortcutLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortcuts")
                .font(.headline)
            ShortcutRow(keys: "hold fn", action: "Dictate into the focused app; release to insert")
            ShortcutRow(keys: "fn + esc", action: "Cancel without inserting")
            ShortcutRow(keys: "⌘↩", action: "Start or stop dictation in this window")
            ShortcutRow(keys: "⇧⌘C", action: "Copy the last transcript")
            Text("If fn opens the emoji picker or Apple Dictation, set System Settings > Keyboard > “Press 🌐 key to” to “Do Nothing”. Some external keyboards do not send fn.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcriptText: String {
        // While recording, show the live partial even if an earlier committed transcript exists.
        let liveText = manager.transcriptState.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if manager.transcriptState.isRecording, !liveText.isEmpty {
            return liveText
        }

        let finalText = manager.transcriptState.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            return finalText
        }

        if !liveText.isEmpty {
            return liveText
        }

        return manager.lastTranscript
    }
}

private struct SetupRow<Actions: View>: View {
    let title: String
    let detail: String
    let isDone: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isDone ? Color.green : Color.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !isDone {
                HStack(spacing: 6) { actions() }
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(isDone ? "done" : "action needed")")
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .frame(minWidth: 72, alignment: .leading)
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
