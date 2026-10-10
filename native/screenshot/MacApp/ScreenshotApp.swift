import SwiftUI

@main
struct ScreenshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // AppDelegate owns the only Settings window (it restores the accessory activation
        // policy on close), so the scene is empty and ⌘, routes to that window.
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Screenshot") {
                    appDelegate.showSettings(tab: .about)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettings(tab: .general)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
