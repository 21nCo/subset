import AppKit
import SystemCore
import SystemDisk
import SystemProcesses

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SystemMonitor()
    private let processes = ProcessesWindowModel()
    private let disk = DiskWindowModel()
    private let openRouter: OpenRouterAccount
    /// Made with the OpenRouter account before whether a key is stored is first read, so it hears every check.
    private let explain: ExplainCenter
    private let mainWindowState = MainWindowState()
    /// Ask (SET-51), with the provider Explain uses; a citation shows its section and selects what it cites.
    private lazy var ask = AskCenter(explain: explain, source: AskWindowSource(
        processes: processes, disk: disk,
        showProcesses: { [mainWindowState] in mainWindowState.section = .processes },
        showDisk: { [mainWindowState] in mainWindowState.section = .disk }
    ))
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
            content: MainWindowView(state: mainWindowState, processes: processes, disk: disk, monitor: monitor,
                                    explain: explain, ask: ask) { [weak self] in self?.perform(.settings) }
        )
        controller.onVisibilityChange = { [monitor, processes] visible in
            monitor.setMainWindowVisible(visible)
            processes.setCadence(monitor.cadence)
        }
        return controller
    }()
    private lazy var settingsWindow = PlaceholderWindowController(
        title: "Settings",
        autosaveName: "SystemSettingsWindow",
        size: NSSize(width: 560, height: 640),
        content: SettingsView(center: explain, openRouter: openRouter)
    )
    private var statusMenu: StatusMenuController?

    override init() {
        let openRouter = OpenRouterAccount.live()
        self.openRouter = openRouter
        explain = ExplainCenter.live(openRouter: openRouter)
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Info.plist sets LSUIElement for the bundled app; the SwiftPM executable has no Info.plist, so set the
        // policy here too and both stay out of the Dock.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make(perform: perform, processes: processes, window: mainWindowState) { [weak self] in
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
        // Whether an OpenRouter key is stored, read off the main actor.
        Task { await openRouter.refreshKey() }
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
        mainWindowState.section = .processes
        processes.reveal(group)
        mainWindow.show()
    }

    func perform(_ command: ShellCommand) {
        switch command {
        case .openSystem: mainWindow.show()
        case .settings:
            settingsWindow.show()
            // Closing Settings only hides it, so the provider's availability, and whether an OpenRouter key is
            // stored, are read again each time it is shown: whether a key is stored first, so the availability read is
            // the latest check of whether OpenRouter can be used (`OpenRouterChecks`) and its answer is the one that
            // counts.
            Task { await openRouter.refreshKey() }
            Task { await explain.refreshAvailability() }
        case .commandLineHelper: showCommandLineHelper()
        case .about:
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit: NSApp.terminate(nil)
        }
    }

    /// Explains the bundled read-only helper and how to link it onto PATH. Copy Command writes the command to the
    /// clipboard; nothing is linked, run, or written anywhere else.
    private func showCommandLineHelper() {
        let helper = CommandLineHelper.path(inApp: Bundle.main.bundlePath)
        let alert = NSAlert()
        alert.messageText = "Command-Line Helper"
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            alert.informativeText = "This build has no \(CommandLineHelper.name) helper. Builds of the Xcode project include it in Contents/Helpers."
            NSApp.activate()
            alert.runModal()
            return
        }
        let command = CommandLineHelper.linkCommand(helperPath: helper)
        alert.informativeText = """
            \(CommandLineHelper.name) prints this Mac's CPU and memory by origin as text or JSON, for you or \
            an agent that runs shell commands. It only reads: it never cleans up, changes, or sends anything.

            To run it from Terminal, link it into a folder on your PATH, for example:

            \(command)

            System never edits shell files or /usr/local itself. Run \(CommandLineHelper.name) --help for its commands.
            """
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }
}
