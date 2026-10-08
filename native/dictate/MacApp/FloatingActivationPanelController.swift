import AppKit
import SwiftUI

@MainActor
final class FloatingActivationPanelController {
    static let shared = FloatingActivationPanelController()

    private var panel: NSPanel?

    func showForSession(manager: DictationManager) {
        show(manager: manager)
    }

    func endSessionVisibility() {
        hide()
    }

    private func show(manager: DictationManager) {
        let panel = panel ?? makePanel(manager: manager)
        updateContent(of: panel, manager: manager)
        position(panel: panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(manager: DictationManager) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 132, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.setContentSize(NSSize(width: 132, height: 34))
        updateContent(of: panel, manager: manager)
        self.panel = panel
        return panel
    }

    private func updateContent(of panel: NSPanel, manager: DictationManager) {
        panel.contentView = NSHostingView(
            rootView: FloatingActivationView()
                .environmentObject(manager)
        )
    }

    private func position(panel: NSPanel) {
        let targetScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - (panelSize.width / 2),
            y: visibleFrame.minY + 18
        )

        panel.setFrameOrigin(origin)
    }
}
