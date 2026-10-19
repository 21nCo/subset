import AppKit
import HopCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsWindow = SettingsWindowController()
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_: Notification) {
        // Info.plist sets LSUIElement for the bundled app; the SwiftPM executable has no Info.plist, so set the
        // policy here too and both stay out of the Dock.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make(perform: perform)
        statusMenu = StatusMenuController(perform: perform)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// Reopening the app from Finder or `open` while it runs shows Settings, since there is no Dock icon or main
    /// window.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { perform(.settings) }
        return true
    }

    func perform(_ command: ShellCommand) {
        switch command {
        case .settings: settingsWindow.show()
        case .about:
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit: NSApp.terminate(nil)
        }
    }
}
