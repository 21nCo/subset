import AppKit
import SwiftUI

@MainActor
final class AvatarWindowController {
    private let appState: LauncherAppState
    private let window: NSPanel

    init(appState: LauncherAppState) {
        self.appState = appState

        let frame = Self.defaultFrame()

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
        // A display that was unplugged, or a drag off-screen, must not strand the button.
        let isOnScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        if !isOnScreen {
            window.setFrame(Self.defaultFrame(), display: false)
        }
        window.orderFrontRegardless()
    }

    private static func defaultFrame() -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(x: screenFrame.maxX - 82, y: screenFrame.midY, width: 54, height: 54)
    }

    func hide() {
        window.orderOut(nil)
    }
}
