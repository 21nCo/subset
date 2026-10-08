import SwiftUI

/// Compact always-on-top recorder shown while a recording is in progress.
struct FloatingRecorderView: View {
    @EnvironmentObject private var recorder: RecordingManager

    var body: some View {
        HStack(spacing: 14) {
            Button {
                recorder.stopRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.gray.opacity(0.4))
                        .frame(width: 30, height: 30)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white)
                        .frame(width: 10, height: 10)
                }
            }
            .buttonStyle(.plain)
            .disabled(!recorder.isRecording)
            .help("Stop and save (⌘R in the main window)")
            .accessibilityLabel("Stop recording")

            VStack(alignment: .leading, spacing: 6) {
                Text(recorder.isRecording ? "Recording" : "Standby")
                    .font(.headline)
                Text(DurationFormatting.clockString(from: recorder.elapsedTime))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)

            WaveformView(
                samples: Array(recorder.waveformSamples.suffix(20)),
                mode: .recording,
                playheadPosition: 0.94
            )
                .frame(width: 130, height: 56)
                .accessibilityHidden(true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(8)
    }
}
