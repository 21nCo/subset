#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingRecorderPanelController {
    static let shared = FloatingRecorderPanelController()

    private var panel: NSPanel?
    private var recordingObservation: AnyCancellable?

    /// Shows the panel while recording and hides it afterwards. The subscription lives in this
    /// controller, not in a window's view, so it keeps working after the main window is closed.
    func bind(to recorder: RecordingManager) {
        guard recordingObservation == nil else { return }
        recordingObservation = recorder.$isRecording
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak recorder] isRecording in
                guard let self, let recorder else { return }
                MainActor.assumeIsolated {
                    if isRecording {
                        self.show(recorder: recorder)
                    } else {
                        self.hide()
                    }
                }
            }
    }

    func show(recorder: RecordingManager) {
        let panel = panel ?? makePanel(recorder: recorder)
        updateContent(of: panel, recorder: recorder)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(recorder: RecordingManager) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Keep the timer and stop control visible while another app is active.
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        // Closing the panel mid-recording would remove the stop control until the next recording.
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.setContentSize(NSSize(width: 340, height: 120))
        updateContent(of: panel, recorder: recorder)
        position(panel)
        self.panel = panel
        return panel
    }

    /// Places a new panel near the top-right of the active screen's visible area.
    private func position(_ panel: NSPanel) {
        guard let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let margin: CGFloat = 24
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - size.width - margin,
            y: visibleFrame.maxY - size.height - margin
        ))
    }

    private func updateContent(of panel: NSPanel, recorder: RecordingManager) {
        panel.contentView = NSHostingView(
            rootView: FloatingRecorderView()
                .environmentObject(recorder)
        )
    }
}
#endif
