import AppKit
import SwiftUI

@MainActor
final class RecordingControlsPanelController {
    private let appState: AppState
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt: Date?

    init(appState: AppState) {
        self.appState = appState
    }

    func show(area: CGRect) {
        hide()
        let size = CGSize(width: 246, height: 54)
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.intersects(area) })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let origin = CGPoint(x: min(max(visibleFrame.minX + 12, area.midX - size.width / 2), visibleFrame.maxX - size.width - 12), y: max(visibleFrame.minY + 12, area.minY - size.height - 14))
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: RecordingControlsView(appState: appState))
        panel.orderFrontRegardless()
        self.panel = panel
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.appState.recordingDuration = Date().timeIntervalSince(startedAt)
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct RecordingControlsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 10, height: 10)
            Text(duration)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 62, alignment: .leading)
            Button {
                appState.toggleRecordingPause()
            } label: {
                Image(systemName: appState.recordingService.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            Button {
                appState.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(width: 246, height: 54)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.18)))
    }

    private var duration: String {
        let total = Int(appState.recordingDuration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
