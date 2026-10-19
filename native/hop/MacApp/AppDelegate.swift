import AppKit
import HopCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the onboarding window has opened on its own, so it opens unasked only on the first launch.
    private static let onboardingShownKey = "onboarding.shown"

    private let settingsWindow = SettingsWindowController()
    private var statusMenu: StatusMenuController?
    private let switchShortcut = SwitchShortcutController()
    private var accessibility = AccessibilityGate()
    private lazy var onboarding = OnboardingWindowController(
        shortcutPhrase: {
            let shortcut = ShortcutStore().shortcut
            return "\(shortcut.modifierSymbol) and press \(shortcut.keyName)"
        },
        onTick: { [unowned self] in refreshAccessibility() }
    )

    func applicationDidFinishLaunching(_: Notification) {
        // Info.plist sets LSUIElement for the bundled app; the SwiftPM executable has no Info.plist, so set the
        // policy here too and both stay out of the Dock.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make(perform: perform)
        statusMenu = StatusMenuController(perform: perform, ready: false)
        switchShortcut.onTrustLost = { [unowned self] in refreshAccessibility() }
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

    /// Trust is re-checked whenever Hop becomes active, for example when a window of its own comes to the front.
    func applicationDidBecomeActive(_: Notification) {
        refreshAccessibility()
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

    /// Samples the Accessibility permission: installs the event tap when it is granted and removes it when it is
    /// revoked. A tap the system refused while trusted is retried on the next sample.
    private func refreshAccessibility() {
        switch accessibility.update(trusted: AccessibilityPermission.isTrusted) {
        case .granted: onboarding.close()
        case .revoked: switchShortcut.remove()
        case nil: break
        }
        if accessibility.isTrusted == true, !switchShortcut.isInstalled {
            switchShortcut.install()
        }
        statusMenu?.update(ready: switchShortcut.isInstalled)
    }
}
