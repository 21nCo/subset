import AppKit
import SwiftUI

/// One reusable window. Closing hides it; showing it again brings back the same window.
@MainActor
final class PlaceholderWindowController {
    private let window: NSWindow

    init(title: String, autosaveName: String, size: NSSize, content: some View) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName(autosaveName)
    }

    func show() {
        // An accessory app is not active until asked; activate so the window comes to the front with focus.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// The main window's placeholder; later issues replace it with the analysis view.
struct MainPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("System")
                .font(.title2.bold())
            Text("Nothing to show yet.")
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
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
