import SwiftUI

/// The floating capsule shown while the dictation hotkey is held.
/// It shows live microphone level while listening and a progress state while the final transcript is prepared.
struct FloatingActivationView: View {
    @EnvironmentObject private var manager: DictationManager

    var body: some View {
        Group {
            if manager.isFinalizing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Transcribing")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .frame(height: 16)
            } else {
                HStack(spacing: 3.5) {
                    ForEach(0..<8, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(.white.opacity(manager.transcriptState.isRecording ? 0.96 : 0.42))
                            .frame(width: 3.8, height: barHeight(for: index))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if manager.isFinalizing {
            return "Dictate is transcribing"
        }
        // Escape cancels only while fn is held; a window-started session is stopped from the window.
        return manager.transcriptState.isRecording ? "Dictate is listening. Release fn to insert, or press Escape while holding fn to cancel." : "Dictate is idle"
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(manager.microphoneLevel)
        let multipliers: [CGFloat] = [0.35, 0.55, 0.82, 1.0, 1.0, 0.82, 0.55, 0.35]
        let baseHeight: CGFloat = 5
        let maxExtraHeight: CGFloat = 11
        return baseHeight + maxExtraHeight * level * multipliers[index]
    }
}
