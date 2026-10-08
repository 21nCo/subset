import AppKit
import SwiftUI

@MainActor
final class AvatarWindowController {
    private let appState: LauncherAppState
    private let window: NSPanel

    init(appState: LauncherAppState) {
        self.appState = appState

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screenFrame.maxX - 82, y: screenFrame.midY, width: 54, height: 54)

        window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: AvatarView(appState: appState))
    }

    func show() {
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}
