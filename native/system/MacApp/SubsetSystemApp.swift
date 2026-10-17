import AppKit

/// AppKit entry point. A status-item app does not need a SwiftUI scene, and owning both windows in AppKit keeps
/// Settings… reachable from the status menu without the SwiftUI settings-scene workarounds.
@main
enum SubsetSystemApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // NSApplication holds its delegate weakly; this local lives until run() returns at exit.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
