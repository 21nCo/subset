import AppKit
import HopCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the onboarding window has opened on its own, so it opens unasked only on the first launch.
    private static let onboardingShownKey = "onboarding.shown"

    private let settings = SettingsModel()
    private lazy var settingsWindow = SettingsWindowController(model: settings)
    private var statusMenu: StatusMenuController?
    private let windowList = WindowListController()
    private lazy var switchShortcut = SwitchShortcutController(
        windowList: windowList,
        settings: { [unowned self] in settings.settings },
        capturesThumbnails: { [unowned self] in settings.capturesThumbnails() }
    )
    private var accessibility = AccessibilityGate()
    private lazy var onboarding = OnboardingWindowController(
        shortcutPhrase: { [unowned self] in
            let shortcut = settings.settings.shortcut
            return "\(shortcut.modifierSymbol) and press \(shortcut.keyName)"
        },
        onTick: { [unowned self] in refreshAccessibility() }
    )

    func applicationDidFinishLaunching(_: Notification) {
        // Info.plist sets LSUIElement for the bundled app; the SwiftPM executable has no Info.plist, so set the
        // policy here too and both stay out of the Dock.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make(perform: perform)
        statusMenu = StatusMenuController(perform: perform, state: .needsPermission)
        // Settings apply at once: the shortcut, and the shown windows in an open switcher.
        settings.onChange = { [unowned self] in switchShortcut.settingsChanged($0) }
        settings.onRecordingChange = { [unowned self] in switchShortcut.isSuspended = $0 }
        switchShortcut.onTrustLost = { [unowned self] in refreshAccessibility() }
        switchShortcut.onNeedsPermission = { [unowned self] in
            refreshAccessibility()
            onboarding.show()
        }
        refreshAccessibility()

        let defaults = UserDefaults.standard
        if AccessibilityGate.showsOnboardingAtLaunch(
            trusted: accessibility.isTrusted == true,
            onboardingShownBefore: defaults.bool(forKey: Self.onboardingShownKey)
        ) {
            defaults.set(true, forKey: Self.onboardingShownKey)
            onboarding.show()
        }
    }

    /// Trust, the login item and Screen Recording are re-checked whenever Hop becomes active, for example when a window
    /// of its own comes to the front after the user changed them in System Settings.
    func applicationDidBecomeActive(_: Notification) {
        refreshAccessibility()
        settings.refreshLoginItem()
        settings.refreshScreenRecording()
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
        case .grantAccessibility: onboarding.show()
        case .settings: settingsWindow.show()
        case .about:
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit: NSApp.terminate(nil)
        }
    }

    /// Samples the Accessibility permission: installs the event tap and starts following window focus when it is
    /// granted, and removes the tap and stops following focus when it is revoked. A tap the system refused while
    /// trusted is retried on the next sample. Any sample that finds trust held closes the onboarding window, whether or
    /// not the tap could be installed.
    private func refreshAccessibility() {
        if accessibility.update(trusted: AccessibilityPermission.isTrusted) == .revoked {
            switchShortcut.remove()
            windowList.stop()
        }
        let trusted = accessibility.isTrusted == true
        settings.isAccessibilityTrusted = trusted
        if trusted {
            onboarding.close()
            windowList.start()
            if !switchShortcut.isInstalled { switchShortcut.install() }
        }
        statusMenu?.update(state: !trusted ? .needsPermission : (switchShortcut.isInstalled ? .ready : .shortcutUnavailable))
    }
}
