import SwiftUI

@main
struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // An accessory app still needs a scene. Settings… (⌘,) explains where options live
        // instead of opening an empty window.
        Settings {
            Text("Launcher has no settings yet. Use the menu bar item to show the floating button, open Quick Notes, or quit.")
                .padding(24)
                .frame(width: 360)
        }
    }
}
