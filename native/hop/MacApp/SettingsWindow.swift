import AppKit
import SwiftUI

/// The Settings window. Closing hides it; showing it again brings back the same window.
@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init() {
        let size = NSSize(width: 460, height: 260)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Hop Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsPlaceholderView())
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName("HopSettingsWindow")
    }

    func show() {
        // An accessory app is not active until asked; activate so the window comes to the front with focus.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// The Settings window's placeholder; later issues add their settings here.
struct SettingsPlaceholderView: View {
    var body: some View {
        Text("No settings yet.")
            .foregroundStyle(.secondary)
            .padding(32)
            .frame(minWidth: 360, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
    }
}
