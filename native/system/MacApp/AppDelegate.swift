import AppKit
import SystemCore
import SystemProcesses

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SystemMonitor()
    private let processes = ProcessesWindowModel()
    /// Whether `mainWindow` exists, so checking whether it is key does not create it.
    private var mainWindowCreated = false
    /// Created on first open: a list updated while its window has never been on screen trips AppKit's
    /// table-reentrancy warning.
    private lazy var mainWindow: PlaceholderWindowController = {
        mainWindowCreated = true
        let controller = PlaceholderWindowController(
            title: "System",
            autosaveName: "SystemMainWindow",
            size: NSSize(width: 980, height: 640),
            content: ProcessesView(model: processes, monitor: monitor)
        )
        controller.onVisibilityChange = { [monitor, processes] visible in
            monitor.setMainWindowVisible(visible)
            processes.setCadence(monitor.cadence)
        }
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
        NSApp.mainMenu = MainMenu.make(perform: perform, processes: processes) { [weak self] in
            guard let self, mainWindowCreated else { return false }
            return mainWindow.isKey
        }
        let statusMenu = StatusMenuController(perform: perform) { [weak self] group in self?.open(group) }
        self.statusMenu = statusMenu
        monitor.onUpdate = { [monitor, processes] in
            if let error = monitor.sampleError {
                processes.applyFailure(error, memory: monitor.memory, at: monitor.memoryObservedAt ?? .now,
                                       cadence: monitor.cadence)
            } else if let sample = monitor.sample {
                processes.apply(sample, memory: monitor.memory, memoryObservedAt: monitor.memoryObservedAt,
                                cadence: monitor.cadence)
            }
            statusMenu.update(monitor.summary, logicalCoreCount: monitor.snapshot?.logicalCoreCount,
                              topGroups: TopGroups(attribution: monitor.sample?.attribution, samplingFailed: monitor.sampleError != nil))
        }
        statusMenu.update(monitor.summary, logicalCoreCount: nil, topGroups: TopGroups(attribution: nil, samplingFailed: false))
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

    /// Opens the window on one group, from the menu bar's top groups.
    private func open(_ group: OriginGroupID) {
        processes.reveal(group)
        mainWindow.show()
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
