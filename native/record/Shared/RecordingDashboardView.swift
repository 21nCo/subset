import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct RecordingDashboardView: View {
    @EnvironmentObject private var recorder: RecordingManager

    let platformTitle: String
    let secondaryNote: String

    @State private var pendingDeletion: RecordingItem?

    private var contentPadding: CGFloat {
        isPhoneLayout ? 20 : 24
    }

    private var cardPadding: CGFloat {
        isPhoneLayout ? 20 : 24
    }

    private var rowPadding: CGFloat {
        isPhoneLayout ? 16 : 18
    }

    private var isPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var displayedWaveformSamples: [CGFloat] {
        recorder.isRecording ? recorder.waveformSamples : []
    }

    private var waveformHeadline: String {
        recorder.isRecording ? "Recording" : "Idle"
    }

    private var waveformIcon: String {
        recorder.isRecording ? "waveform.circle.fill" : "pause.circle"
    }

    private var waveformAccent: Color {
        recorder.isRecording ? .red : .secondary
    }

    private var waveformClockValue: TimeInterval {
        recorder.isRecording ? recorder.elapsedTime : 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerCard
                waveformCard
                controls
                latestRecordingCard
                recordingsCard
            }
            .padding(contentPadding)
            .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 620)
        }
        .background(RecordPalette.window)
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { recording in
            Button("Delete Recording", role: .destructive) {
                recorder.deleteRecording(recording)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { recording in
            Text("\(recordingTitle(for: recording)) will be removed from this device. This cannot be undone.")
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(platformTitle)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary)

            Text(secondaryNote)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    statusPill(title: "Status", value: recorder.statusMessage)
                    statusPill(title: "Microphone", value: recorder.permissionStatusText)
                }

                VStack(spacing: 12) {
                    statusPill(title: "Status", value: recorder.statusMessage)
                    statusPill(title: "Microphone", value: recorder.permissionStatusText)
                }
            }

            if recorder.isPermissionDenied {
                HStack(spacing: 12) {
                    Label("Microphone access is off, so Record cannot capture audio.", systemImage: "mic.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Open Settings") {
                        recorder.openMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let errorMessage = recorder.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(RecordPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var waveformCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(waveformHeadline, systemImage: waveformIcon)
                    .font(.headline)
                    .foregroundStyle(waveformAccent)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(DurationFormatting.clockString(from: waveformClockValue))
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)

                }
            }

            WaveformView(
                samples: displayedWaveformSamples,
                mode: .recording,
                baselineColor: Color(red: 0.20, green: 0.44, blue: 0.95).opacity(0.22),
                showPlayhead: recorder.isRecording,
                playheadPosition: 0.94,
                onScrub: nil
            )
                .frame(height: 150)
                .modifier(RecordingWaveformCardStyle())
                .accessibilityElement()
                .accessibilityLabel(recorder.isRecording ? "Live waveform" : "Waveform, idle")
                .accessibilityValue(DurationFormatting.clockString(from: waveformClockValue))

            if !recorder.isRecording {
                Text("Start recording to see the live waveform here. Playback waveform stays with the clip below.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(RecordPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var controls: some View {
        // Stack the buttons on narrow phone widths instead of truncating their labels.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { controlButtons }
            VStack(spacing: 12) { controlButtons }
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        Button {
            recorder.toggleRecording()
        } label: {
            Label(recorder.isRecording ? "Stop Recording" : "Start Recording", systemImage: recorder.isRecording ? "stop.fill" : "record.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(recorder.isRecording ? .red : .accentColor)
        .keyboardShortcut("r", modifiers: .command)
        .help(recorder.isRecording ? "Stop and save the recording (⌘R)" : "Start a new recording (⌘R)")

        Button("Reset Waveform") {
            recorder.resetVisualization()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(recorder.isRecording)
    }

    @ViewBuilder
    private var latestRecordingCard: some View {
        if let latestRecording = recorder.savedRecordings.first {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick playback")
                    .font(.headline)
                    .foregroundStyle(Color.primary)

                recordingSummary(for: latestRecording, emphasis: .primary)
                recordingActionRow(for: latestRecording)
                playbackWaveform(for: latestRecording)
            }
            .padding(cardPadding)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(RecordPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var recordingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Local recordings")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }

            if recorder.savedRecordings.isEmpty {
                Text("No recordings yet. Press Start Recording (⌘R on a keyboard) and your clips will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if recorder.savedRecordings.count == 1 {
                Text("Older recordings will appear here as you create more clips.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(recorder.savedRecordings.dropFirst())) { recording in
                    savedRecordingRow(recording: recording)
                }
            }
        }
        .padding(cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(RecordPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func savedRecordingRow(recording: RecordingItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingSummary(for: recording)
            recordingActionRow(for: recording)
            playbackWaveform(for: recording)
        }
        .padding(rowPadding)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(RecordPalette.row)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func recordingActionRow(for recording: RecordingItem) -> some View {
        HStack(spacing: 10) {
            primaryPlaybackButton(for: recording, title: recorder.isPlaying(recording) ? "Stop" : "Play")
            compactAccessoryButton(for: recording.url)
            Spacer(minLength: 0)
            Button(role: .destructive) {
                pendingDeletion = recording
            } label: {
                Image(systemName: "trash")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(recorder.isRecording)
            .help("Delete recording")
            .accessibilityLabel("Delete recording from \(recordingTitle(for: recording))")
        }
    }

    private func primaryPlaybackButton(for recording: RecordingItem, title: String) -> some View {
        Button {
            recorder.togglePlayback(for: recording)
        } label: {
            Label(title, systemImage: recorder.isPlaying(recording) ? "stop.fill" : "play.fill")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .fixedSize(horizontal: true, vertical: false)
        .tint(recorder.isPlaying(recording) ? .red : Color(red: 0.20, green: 0.44, blue: 0.95))
        .disabled(recorder.isRecording)
    }

    @ViewBuilder
    private func compactAccessoryButton(for url: URL) -> some View {
        #if os(iOS)
        ShareLink(item: url) {
            Image(systemName: "square.and.arrow.up")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel("Share recording")
        #elseif os(macOS)
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Image(systemName: "folder")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help("Show in Finder")
        .accessibilityLabel("Show recording in Finder")
        #endif
    }

    private func recordingSummary(for recording: RecordingItem, emphasis: RecordingSummaryEmphasis = .standard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recordingTitle(for: recording))
                .font(.headline)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(recordingSubtitle(for: recording))
                .font(emphasis == .primary ? .subheadline.weight(.medium) : .caption.weight(.medium))
                .foregroundStyle(Color.secondary)

            if !isPhoneLayout || emphasis == .primary {
                Text(recording.url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func recordingTitle(for recording: RecordingItem) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(recording.createdAt) {
            return "Today at \(recording.createdAt.formatted(date: .omitted, time: .shortened))"
        }

        return recording.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func recordingSubtitle(for recording: RecordingItem) -> String {
        "\(DurationFormatting.clockString(from: recording.duration)) • \(recordingFormat(for: recording))"
    }

    private func recordingFormat(for recording: RecordingItem) -> String {
        recording.url.pathExtension.uppercased()
    }

    private func playbackWaveform(for recording: RecordingItem) -> some View {
        let isActivePlayback = recorder.isPlaying(recording)
        let samples = isActivePlayback
            ? (recorder.playbackWaveformSamples.isEmpty ? recorder.waveformPreviewSamples(for: recording) : recorder.playbackWaveformSamples)
            : recorder.waveformPreviewSamples(for: recording)
        let elapsed = isActivePlayback ? recorder.playbackTime : 0
        let remaining = max(recording.duration - elapsed, 0)

        return VStack(alignment: .leading, spacing: 8) {
            WaveformView(
                samples: samples,
                mode: .playback,
                waveformColor: Color(red: 0.20, green: 0.44, blue: 0.95),
                baselineColor: Color.primary.opacity(isActivePlayback ? 0.14 : 0.18),
                showPlayhead: isActivePlayback,
                playheadPosition: isActivePlayback ? CGFloat(recorder.playbackProgress) : 0,
                showsBorder: true,
                cornerRadius: 20,
                onScrub: isActivePlayback ? { progress in
                    recorder.seekPlayback(to: progress)
                } : nil
            )
            .frame(height: 92)

            HStack(spacing: 12) {
                Label(DurationFormatting.clockString(from: elapsed), systemImage: "play.fill")
                    .foregroundStyle(isActivePlayback ? Color(red: 0.20, green: 0.44, blue: 0.95) : Color.secondary)

                Spacer()

                Text(DurationFormatting.clockString(from: recording.duration))
                    .foregroundStyle(Color.secondary)

                if isActivePlayback {
                    Text("left \(DurationFormatting.clockString(from: remaining))")
                        .foregroundStyle(Color.secondary)
                }
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
        }
    }

    private func statusPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private enum RecordingSummaryEmphasis {
    case standard
    case primary
}

private struct RecordingWaveformCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(red: 0.20, green: 0.44, blue: 0.95).opacity(0.12), lineWidth: 1)
            )
    }
}

/// Semantic colors so the dashboard follows light and dark appearance.
enum RecordPalette {
    #if os(iOS)
    static let window = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let row = Color(uiColor: .tertiarySystemGroupedBackground)
    #else
    static let window = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let row = Color(nsColor: .underPageBackgroundColor)
    #endif
}
