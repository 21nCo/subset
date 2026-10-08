import AppKit
import SwiftUI

/// Hosts the saved quick notes. This replaces the POC's mock "full app" workspace,
/// which only displayed hard-coded sample Nucleum goals and nodes.
@MainActor
final class QuickNotesWindowController {
    private let appState: LauncherAppState
    private var window: NSWindow?

    init(appState: LauncherAppState) {
        self.appState = appState
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quick Notes"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        window.contentView = NSHostingView(rootView: QuickNotesView(appState: appState))
        window.center()
        return window
    }
}
