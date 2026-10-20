import AppKit
import SystemCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SystemMonitor()
    /// Created on first open: a table updated while its window has never been on screen trips AppKit's
    /// table-reentrancy warning.
    private lazy var mainWindow: PlaceholderWindowController = {
        let controller = PlaceholderWindowController(
            title: "System",
            autosaveName: "SystemMainWindow",
            size: NSSize(width: 820, height: 520),
            content: ProcessTableView(monitor: monitor)
        )
        controller.onVisibilityChange = { [monitor] visible in monitor.setMainWindowVisible(visible) }
        return controller
    }()
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
        let statusMenu = StatusMenuController(perform: perform)
        self.statusMenu = statusMenu
        monitor.onUpdate = { [monitor] in
            statusMenu.update(monitor.summary, logicalCoreCount: monitor.snapshot?.logicalCoreCount)
        }
        statusMenu.update(monitor.summary, logicalCoreCount: nil)
        monitor.start()
    }

    func applicationWillTerminate(_: Notification) {
        monitor.stopContainerPolling()
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
