#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class FloatingRecorderPanelController {
    static let shared = FloatingRecorderPanelController()

    private var panel: NSPanel?

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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.setContentSize(NSSize(width: 340, height: 120))
        updateContent(of: panel, recorder: recorder)
        self.panel = panel
        return panel
    }

    private func updateContent(of panel: NSPanel, recorder: RecordingManager) {
        panel.contentView = NSHostingView(
            rootView: FloatingRecorderView()
                .environmentObject(recorder)
        )
    }
}
#endif
