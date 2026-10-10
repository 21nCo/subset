import ActivityKit
import SwiftUI
import WidgetKit

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.05, green: 0.08, blue: 0.16))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "mic.fill")
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    recordingTimer(startedAt: context.state.startedAt)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WaveformView(
                        samples: context.state.samples.map { CGFloat($0) },
                        mode: .recording,
                        waveformColor: .white,
                        baselineColor: .white.opacity(0.55),
                        borderColor: .white.opacity(0.12),
                        backgroundColor: .white.opacity(0.04),
                        showPlayhead: true,
                        playheadPosition: 0.94,
                        showsBorder: true,
                        cornerRadius: 10
                    )
                        .frame(height: 34)
                }
            } compactLeading: {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.red)
            } compactTrailing: {
                recordingTimer(startedAt: context.state.startedAt)
                    .font(.caption2)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func lockScreenView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(context.state.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                recordingTimer(startedAt: context.state.startedAt)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }

            Spacer(minLength: 16)

            WaveformView(
                samples: context.state.samples.map { CGFloat($0) },
                mode: .recording,
                waveformColor: .white,
                baselineColor: .white.opacity(0.58),
                borderColor: .white.opacity(0.14),
                backgroundColor: .white.opacity(0.05),
                showPlayhead: true,
                playheadPosition: 0.94,
                showsBorder: true,
                cornerRadius: 12
            )
                .frame(width: 148, height: 48)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func recordingTimer(startedAt: Date) -> some View {
        Text(startedAt, style: .timer)
            .monospacedDigit()
    }
}
