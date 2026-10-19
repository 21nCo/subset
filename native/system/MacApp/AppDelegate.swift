import AppKit
import SystemCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mainWindow = PlaceholderWindowController(
        title: "System",
        autosaveName: "SystemMainWindow",
        size: NSSize(width: 640, height: 420),
        content: MainPlaceholderView()
    )
    private let settingsWindow = PlaceholderWindowController(
        title: "Settings",
        autosaveName: "SystemSettingsWindow",
        size: NSSize(width: 460, height: 260),
        content: SettingsPlaceholderView()
    )
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_: Notification) {
        // Info.plist sets LSUIElement for the bundled app; the SwiftPM executable has no Info.plist, so set the
        // policy here too and both stay out of the Dock.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make(perform: perform)
        statusMenu = StatusMenuController(perform: perform)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// Reopening the app from Finder or `open` while it runs shows the main window, since there is no Dock icon.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { perform(.openSystem) }
        return true
    }

    func perform(_ command: ShellCommand) {
        switch command {
        case .openSystem: mainWindow.show()
        case .settings: settingsWindow.show()
        case .about:
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit: NSApp.terminate(nil)
        }
    }
}
