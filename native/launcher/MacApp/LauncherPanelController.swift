import AppKit
import SwiftUI

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    private let appState: LauncherAppState
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?

    init(appState: LauncherAppState) {
        self.appState = appState
        super.init()
    }

    func show(mode: LauncherMode) {
        let panel = panel ?? makePanel()
        self.panel = panel

        appState.mode = mode
        panel.contentView = NSHostingView(rootView: LauncherView(appState: appState))
        panel.setFrame(frame(for: mode), display: true)
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
        appState.markLauncherClosed()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Outside screen clicks are handled by the global mouse monitor. Keeping
        // this empty lets the floating S avatar reliably toggle the panel closed.
    }

    private func makePanel() -> NSPanel {
        let panel = LauncherPanel(
            contentRect: frame(for: .search),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func frame(for mode: LauncherMode) -> NSRect {
        let size = mode == .quickNote ? NSSize(width: 740, height: 420) : NSSize(width: 720, height: 430)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height - 96,
            width: size.width,
            height: size.height
        )
    }
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
