import AppKit
import ApplicationServices
import HopCore
import os

/// Runs the hold-to-switch shortcut while Hop has the Accessibility permission: owns the event tap and the
/// `ShortcutRecognizer` it drives, and hands the switch to the `SwitcherController`: the trigger opens the switcher,
/// steps, row moves and operation keys go to it, releasing the holding modifier commits and Esc or an interruption
/// cancels.
///
/// The tap's callback must return quickly, so the trigger only marks the switcher to open, on the next pass of the main
/// run loop; any input that arrives before then opens it first, so every key is applied to the list it was meant for.
@MainActor
final class SwitchShortcutController {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "switch")

    private let store: ShortcutStore
    private var recognizer: ShortcutRecognizer
    private var tap: EventTap?
    private let switcher: SwitcherController
    /// A trigger was accepted and the switcher has not opened yet.
    private var opening = false
    /// Called when the system disabled the tap and Hop no longer holds the Accessibility permission.
    var onTrustLost: () -> Void = {}
    /// Called when the shortcut, or an operation, finds Hop without the Accessibility permission: samples the
    /// permission again and shows onboarding.
    var onNeedsPermission: () -> Void = {}

    init(windowList: WindowListController, store: ShortcutStore = ShortcutStore()) {
        self.store = store
        recognizer = ShortcutRecognizer(shortcut: store.shortcut)
        switcher = SwitcherController(readWindows: { windowList.refresh().windows }, windowOperator: windowList.windowOperator)
        switcher.onSessionEnded = { [unowned self] in recognizer.endSession() }
        switcher.onNotPermitted = { [unowned self] in onNeedsPermission() }
    }

    var isInstalled: Bool { tap?.isInstalled ?? false }

    /// Installs the tap with the stored shortcut. Call only while the process is trusted; returns false if the
    /// system refused the tap.
    @discardableResult
    func install() -> Bool {
        if isInstalled { return true }
        recognizer.shortcut = store.shortcut
        let tap = EventTap { [unowned self] input in handle(input) }
        guard tap.install() else {
            Self.log.error("The system refused the keyboard event tap")
            return false
        }
        self.tap = tap
        Self.log.info("Switch shortcut \(self.recognizer.shortcut.displayName, privacy: .public) installed")
        return true
    }

    /// Removes the tap and cancels any switch in progress.
    func remove() {
        guard let tap else { return }
        tap.remove()
        self.tap = nil
        opening = false
        _ = recognizer.reset()
        switcher.cancel()
        Self.log.info("Switch shortcut removed")
    }

    private func handle(_ input: TapInput) -> Disposition {
        openIfTriggered()
        let result = recognizer.handle(input)
        switch result.event {
        case .trigger:
            if AXIsProcessTrusted() {
                opening = true
                DispatchQueue.main.async { [weak self] in self?.openIfTriggered() }
            } else {
                // Access was revoked since the last sample: there is no list to show, so ask for it again.
                recognizer.endSession()
                DispatchQueue.main.async { [weak self] in self?.onNeedsPermission() }
            }
        case let event?:
            switcher.apply(event)
        case nil:
            break
        }
        switch result.outcome {
        case .commit: switcher.commit()
        case .cancel: switcher.cancel()
        case nil: break
        }
        if input == .tapDisabled {
            // The system disables a tap whose callback was too slow, or on some user input such as secure text
            // entry. Turn it back on at once unless the permission is gone, which also disables it.
            if AXIsProcessTrusted() {
                Self.log.info("The system disabled the event tap; re-enabled it")
                tap?.reenable()
            } else {
                // Removing the tap from inside its own callback is deferred to the next run loop pass.
                DispatchQueue.main.async { [weak self] in self?.onTrustLost() }
            }
        }
        return result.disposition
    }

    /// Opens the switcher for a trigger the tap accepted, unless the session ended before it could open.
    private func openIfTriggered() {
        guard opening else { return }
        opening = false
        if recognizer.session.isActive { switcher.open() }
    }
}
