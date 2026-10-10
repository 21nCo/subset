import AppKit
import SwiftUI

@main
struct ClipboardMacApp: App {
    @StateObject private var appController = ClipboardAppController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            EmptyView()
                .environmentObject(appController.manager)
                .frame(width: 1, height: 1)
        }
    }
}
