import AppKit
import SwiftUI

/// One reusable window. Closing hides it; showing it again brings back the same window.
@MainActor
final class PlaceholderWindowController {
    private let window: NSWindow
    /// Called on the main actor whenever the window becomes visible on screen or stops being visible (closed,
    /// minimized, fully covered, or on another space).
    var onVisibilityChange: ((Bool) -> Void)?

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
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onVisibilityChange?(self.window.occlusionState.contains(.visible))
            }
        }
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
