import AppKit
import ApplicationServices
import HopCore
import os

/// Runs the hold-to-switch shortcut while Hop has the Accessibility permission: owns the event tap and the
/// `ShortcutRecognizer` it drives, and hands the switch to the `SwitcherController`: the trigger opens the switcher,
/// steps, row moves and operation keys go to it, releasing the holding modifier commits and Esc or an interruption
/// cancels.
///
/// The tap's callback must return quickly and never reads the window list, so the trigger only marks the switcher to
/// open, on the next pass of the main run loop. What the session does before then is held and applied in order once it
/// has opened, so every key is applied to the list it was meant for; a switch cancelled before then never opens.
@MainActor
final class SwitchShortcutController {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "switch")

    private let store: ShortcutStore
    private var recognizer: ShortcutRecognizer
    private var tap: EventTap?
    private let switcher: SwitcherController
    /// A trigger was accepted and the switcher has not opened yet.
    private var opening = false
    /// The trigger and what the session did after it, until the switcher opens.
    private var held: [ShortcutRecognizer.Result] = []
    private let isTrusted: () -> Bool
    /// Called when the system disabled the tap and Hop no longer holds the Accessibility permission.
    var onTrustLost: () -> Void = {}
    /// Called when the shortcut, or an operation, finds Hop without the Accessibility permission: samples the
    /// permission again and shows onboarding.
    var onNeedsPermission: () -> Void = {}

    convenience init(windowList: WindowListController, store: ShortcutStore = ShortcutStore()) {
        self.init(
            switcher: SwitcherController(readWindows: { windowList.refresh() }, windowOperator: windowList.windowOperator),
            store: store
        )
    }

    init(switcher: SwitcherController, store: ShortcutStore, isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.store = store
        self.isTrusted = isTrusted
        recognizer = ShortcutRecognizer(shortcut: store.shortcut)
        self.switcher = switcher
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
        held = []
        _ = recognizer.reset()
        switcher.cancel()
        Self.log.info("Switch shortcut removed")
    }

    func handle(_ input: TapInput) -> Disposition {
        let result = recognizer.handle(input)
        if case .trigger = result.event, !isTrusted() {
            // Access was revoked since the last sample: there is no list to show, so ask for it again.
            recognizer.endSession()
            DispatchQueue.main.async { [weak self] in self?.onNeedsPermission() }
        } else if case .trigger = result.event {
            if !opening { DispatchQueue.main.async { [weak self] in self?.openHeld() } }
            opening = true
            held.append(result)
        } else if opening {
            if result.event != nil || result.outcome != nil { held.append(result) }
        } else {
            apply(result)
        }
        if input == .tapDisabled {
            // The system disables a tap whose callback was too slow, or on some user input such as secure text
            // entry. Turn it back on at once unless the permission is gone, which also disables it.
            if isTrusted() {
                Self.log.info("The system disabled the event tap; re-enabled it")
                tap?.reenable()
            } else {
                // Removing the tap from inside its own callback is deferred to the next run loop pass.
                DispatchQueue.main.async { [weak self] in self?.onTrustLost() }
            }
        }
        return result.disposition
    }

    private func apply(_ result: ShortcutRecognizer.Result) {
        if let event = result.event { switcher.apply(event) }
        switch result.outcome {
        case .commit: switcher.commit()
        case .cancel: switcher.cancel()
        case nil: break
        }
    }

    /// Opens the switcher for each held trigger, unless its switch was cancelled first, and applies what followed it.
    private func openHeld() {
        guard opening else { return }
        opening = false
        let results = held
        held = []
        for (index, result) in results.enumerated() {
            guard case .trigger = result.event else {
                apply(result)
                continue
            }
            if results[(index + 1)...].lazy.compactMap(\.outcome).first != .cancel { switcher.open() }
        }
    }
}
