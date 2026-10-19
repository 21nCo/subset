import AppKit
import ApplicationServices
import HopCore
import os

/// Runs the hold-to-switch shortcut while Hop has the Accessibility permission: owns the event tap and the
/// `ShortcutRecognizer` it drives, and keeps the session's window count current.
///
/// Until the overlay and focusing land (SET-94), a committed switch only logs the selected index, at debug level.
/// Nothing about a window, and never its title, is logged.
@MainActor
final class SwitchShortcutController {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "switch")

    private let store: ShortcutStore
    private var recognizer: ShortcutRecognizer
    private var tap: EventTap?
    private let windowCount = WindowCountPlaceholder()
    /// Called when the system disabled the tap and Hop no longer holds the Accessibility permission.
    var onTrustLost: () -> Void = {}

    init(store: ShortcutStore = ShortcutStore()) {
        self.store = store
        recognizer = ShortcutRecognizer(shortcut: store.shortcut)
        windowCount.onChange = { [weak self] count in self?.listChanged(count: count) }
    }

    var isInstalled: Bool { tap?.isInstalled ?? false }

    /// Installs the tap with the stored shortcut. Call only while the process is trusted; returns false if the
    /// system refused the tap.
    @discardableResult
    func install() -> Bool {
        if isInstalled { return true }
        recognizer.shortcut = store.shortcut
        listChanged(count: windowCount.current)
        let tap = EventTap { [unowned self] input in handle(input) }
        guard tap.install() else {
            Self.log.error("The system refused the keyboard event tap")
            return false
        }
        self.tap = tap
        windowCount.start()
        Self.log.info("Switch shortcut \(self.recognizer.shortcut.displayName, privacy: .public) installed")
        return true
    }

    /// Removes the tap and cancels any switch in progress.
    func remove() {
        guard let tap else { return }
        tap.remove()
        self.tap = nil
        windowCount.stop()
        report(recognizer.reset())
        Self.log.info("Switch shortcut removed")
    }

    private func handle(_ input: TapInput) -> Disposition {
        let result = recognizer.handle(input)
        report(result.outcome)
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

    private func listChanged(count: Int) {
        report(recognizer.listChanged(count: count))
    }

    private func report(_ outcome: SwitchSession.Outcome?) {
        switch outcome {
        case let .commit(index): Self.log.debug("Switch committed at index \(index, privacy: .public)")
        case .cancel: Self.log.debug("Switch cancelled")
        case nil: break
        }
    }
}

/// Stands in for the window list (SET-92) by reporting how many apps with a Dock presence are running, so a switch can
/// start and commit before windows are enumerated. It reads only the count, never names or windows, and updates on
/// app launch and quit instead of polling.
@MainActor
final class WindowCountPlaceholder {
    var onChange: (Int) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []

    var current: Int {
        NSWorkspace.shared.runningApplications.reduce(0) { $0 + ($1.activationPolicy == .regular ? 1 : 0) }
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onChange(self.current)
                }
            })
        }
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }
}
