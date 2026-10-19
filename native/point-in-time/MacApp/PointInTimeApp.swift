import SwiftUI

@main
struct PointInTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A menu-bar app still needs a scene; Settings… points to where the controls live.
        Settings {
            Text("pointInTime is controlled from its menu bar item: pause or stop tracking, exclude apps, delete data, and review permissions.")
                .padding(24)
                .frame(width: 380)
        }
    }
}
