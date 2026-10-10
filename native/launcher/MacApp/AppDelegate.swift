import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = LauncherAppState()
    private var statusBarController: StatusBarController?
    private var superBarController: LauncherPanelController?
    private var avatarController: AvatarWindowController?
    private var quickNotesController: QuickNotesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusBarController = StatusBarController()
        superBarController = LauncherPanelController(appState: appState)
        avatarController = AvatarWindowController(appState: appState)
        quickNotesController = QuickNotesWindowController(appState: appState)

        configureAppIntents()

        appState.onOpenLauncher = { [weak self] mode in
            self?.superBarController?.show(mode: mode)
        }
        appState.onCloseLauncher = { [weak self] in
            self?.superBarController?.hide()
        }
        appState.onOpenQuickNotes = { [weak self] in
            self?.quickNotesController?.show()
        }
        appState.onAvatarVisibilityChanged = { [weak self] isVisible in
            isVisible ? self?.avatarController?.show() : self?.avatarController?.hide()
        }

        // Unit tests use this app as their host; they must not claim system-wide hotkeys.
        var unavailableHotkeys: Set<UInt32> = []
        if !PersistenceController.isRunningUnitTests { unavailableHotkeys = GlobalShortcutMonitor.shared.start(shortcuts: [
            GlobalShortcutRegistration(
                id: 1,
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(optionKey),
                onPress: { [weak self] in self?.appState.openLauncher(mode: .search) }
            ),
            GlobalShortcutRegistration(
                id: 2,
                keyCode: UInt32(kVK_ANSI_N),
                modifiers: UInt32(controlKey | optionKey),
                onPress: { [weak self] in self?.appState.openLauncher(mode: .quickNote) }
            )
        ]) }

        // A hotkey another app already owns is shown as unavailable in the menu instead of
        // being advertised; the menu items still work.
        statusBarController?.configure(
            onOpenLauncher: { [weak self] in self?.appState.openLauncher(mode: .search) },
            onNewQuickNote: { [weak self] in self?.appState.openLauncher(mode: .quickNote) },
            onOpenQuickNotes: { [weak self] in self?.appState.openQuickNotes() },
            isAvatarVisible: { [weak self] in self?.appState.isAvatarVisible ?? false },
            onToggleAvatar: { [weak self] in self?.appState.toggleAvatarVisibility() },
            onQuit: { NSApp.terminate(nil) },
            isLauncherHotkeyAvailable: !unavailableHotkeys.contains(1),
            isQuickNoteHotkeyAvailable: !unavailableHotkeys.contains(2)
        )

        if appState.isAvatarVisible {
            avatarController?.show()
        }
        // The test host must not read the user's folders (which can raise privacy prompts).
        if !PersistenceController.isRunningUnitTests { appState.refreshSearchData() }
        observeActiveApplications()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalShortcutMonitor.shared.stop()
    }

    private func observeActiveApplications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor in
                self?.appState.rememberWindowTarget(app)
            }
        }
    }

    private func configureAppIntents() {
        let bridge = LauncherIntentBridge.shared

        bridge.openSearch = { [weak self] filter in
            self?.appState.openLauncher(mode: .search)
            self?.appState.selectedFilter = filter
        }

        bridge.openQuickNotes = { [weak self] in
            self?.appState.openQuickNotes()
        }

        bridge.openQuickNoteComposer = { [weak self] in
            self?.appState.openLauncher(mode: .quickNote)
        }

        bridge.setAvatarVisible = { [weak self] isVisible in
            self?.appState.setAvatarVisibility(isVisible)
        }

        bridge.quickNotesChanged = { [weak self] in
            self?.appState.reloadQuickNotes()
        }
    }
}
