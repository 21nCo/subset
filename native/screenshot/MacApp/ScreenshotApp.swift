import SwiftUI

@main
struct ScreenshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(appState: appDelegate.appState)
                .frame(minWidth: 760, minHeight: 540)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Screenshot") {
                    appDelegate.showSettings(tab: .about)
                }
            }
        }
    }
}
