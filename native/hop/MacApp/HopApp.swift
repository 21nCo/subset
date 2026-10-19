import AppKit

/// AppKit entry point. A status-item app does not need a SwiftUI scene, and owning the Settings window in AppKit
/// keeps Settings… reachable from the status menu without the SwiftUI settings-scene workarounds.
@main
enum HopApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // NSApplication holds its delegate weakly, and Swift may release a local after its last use, so keep the
        // delegate alive explicitly for as long as the run loop runs.
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
