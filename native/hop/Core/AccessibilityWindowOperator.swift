import Foundation

/// Why an Accessibility request did not succeed, as the host maps `AXError`.
public enum AccessibilityFailure: Error, Sendable, Equatable {
    /// The element no longer exists (`kAXErrorInvalidUIElement`), or Hop no longer knows the window.
    case invalidElement
    /// The app did not answer within the messaging timeout (`kAXErrorCannotComplete`); an app that just exited
    /// answers this way too.
    case timedOut
    /// The element has no such attribute, value, or action, or the attribute cannot be set.
    case unsupported
    /// Hop does not hold the Accessibility permission (`kAXErrorAPIDisabled`).
    case notPermitted
    /// Any other error.
    case failed
}

/// The Accessibility requests the operator makes. The host sends each to the app with the 0.25 s messaging timeout;
/// a window is named by its `WindowRef` and its app's pid, and a ref the host no longer knows is `.invalidElement`.
public protocol WindowAccessibility: Sendable {
    /// Whether Hop holds the Accessibility permission. Asks no app.
    func isTrusted() -> Bool
    /// The window's `kAXMinimized`.
    func isMinimized(_ window: WindowRef, pid: pid_t) throws(AccessibilityFailure) -> Bool
    /// Sets the window's `kAXMinimized`.
    func setMinimized(_ minimized: Bool, window: WindowRef, pid: pid_t) throws(AccessibilityFailure)
    /// Performs `kAXRaiseAction` on the window.
    func raise(_ window: WindowRef, pid: pid_t) throws(AccessibilityFailure)
    /// Sets the window's `kAXMain` to true.
    func makeMain(_ window: WindowRef, pid: pid_t) throws(AccessibilityFailure)
    /// Presses the window's `kAXCloseButton`; `.unsupported` when it has none.
    func pressCloseButton(_ window: WindowRef, pid: pid_t) throws(AccessibilityFailure)
    /// Sets the app element's `kAXFrontmost` to true.
    func makeFrontmost(pid: pid_t) throws(AccessibilityFailure)
    /// The app element's `kAXFrontmost`.
    func isFrontmost(pid: pid_t) throws(AccessibilityFailure) -> Bool
    /// Whether the app's `kAXFocusedWindow` is the window; false when the app has no focused window.
    func isFocused(_ window: WindowRef, pid: pid_t) throws(AccessibilityFailure) -> Bool
    /// Reads an attribute of the window itself, only to learn whether it still exists: `.invalidElement` when it
    /// does not.
    func probe(_ window: WindowRef, pid: pid_t) throws(AccessibilityFailure)
}

/// A running app, as the operator needs it.
public struct RunningAppState: Sendable, Equatable {
    public var bundleIdentifier: String?
    public var isHidden: Bool

    public init(bundleIdentifier: String?, isHidden: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.isHidden = isHidden
    }
}

/// The app requests the operator makes, through `NSRunningApplication` in the host. Each returns whether the request
/// was delivered. There is deliberately no force-quit.
public protocol AppControl: Sendable {
    /// The app running with this pid, or nil when none is.
    func app(_ pid: pid_t) -> RunningAppState?
    func unhide(_ pid: pid_t) -> Bool
    func activate(_ pid: pid_t) -> Bool
    func hide(_ pid: pid_t) -> Bool
    /// Asks the app to quit normally; it may prompt, for example to save.
    func terminate(_ pid: pid_t) -> Bool
}

/// Carries out `WindowOperation`s through a `WindowAccessibility` and an `AppControl`.
///
/// Every operation runs on one serial queue of its own, so the caller is never blocked and operations are carried out
/// in the order they were asked for. Each request to an app gives up after the host's messaging timeout, and one that
/// times out ends the operation, so an app that does not answer costs one timeout, not one per step.
///
/// Before anything else, an operation checks that Hop is trusted (`.notPermitted` otherwise, with no request made)
/// and that the window's app is still running under the same bundle ID (`.appGone` otherwise). A failed request then
/// gives `.windowGone` when the window no longer exists but its app runs, `.appGone` when the app has exited,
/// `.notPermitted` when trust was lost meanwhile, and `.refused` otherwise.
///
/// **focus** unhides the app if it is hidden, sets `kAXMinimized` false if the window is minimized, raises the window,
/// makes it the app's main window, activates the app, and makes the app frontmost; a step the window does not support
/// is skipped, and a window whose minimized state cannot be read is taken as not minimized. Whether activation was
/// taken does not matter by itself: focus succeeds when, within `readBackTimeout` (0.5 s), the app reads back as
/// frontmost and its focused window as this window. Otherwise it is `.windowGone` if the window has meanwhile closed,
/// and `.refused("did not come to front")` if not. **minimize** sets `kAXMinimized` true. **close** presses the close button and
/// is done even if the app then asks to save: Hop leaves that prompt to the user. **hideApp** hides the app, and is
/// done when it was hidden already. **quitApp** asks the app to quit normally, never by force, and Finder is never
/// quit.
///
/// On an app listed without windows (`perform(_:onApp:)`), **focus** unhides the app if it is hidden, activates it and
/// makes it frontmost, and succeeds when the app reads back as frontmost within `readBackTimeout`; **hideApp** and
/// **quitApp** are as above; **minimize** and **close** are refused, since there is no window.
public final class AccessibilityWindowOperator: WindowOperator {
    /// How long focus waits for the window to read back as the app's focused window.
    public static let defaultReadBackTimeout: Duration = .milliseconds(500)
    /// How often focus reads the focused window back while it waits.
    public static let readBackInterval: Duration = .milliseconds(25)
    public static let finderBundleIdentifier = "com.apple.finder"

    private let accessibility: any WindowAccessibility
    private let apps: any AppControl
    private let readBackTimeout: Duration
    private let queue = DispatchQueue(label: "\(HopIdentity.bundleIdentifier).operations", qos: .userInteractive)

    public init(
        accessibility: any WindowAccessibility,
        apps: any AppControl,
        readBackTimeout: Duration = defaultReadBackTimeout
    ) {
        self.accessibility = accessibility
        self.apps = apps
        self.readBackTimeout = readBackTimeout
    }

    public func perform(_ operation: WindowOperation, on window: WindowEntry) async -> OperationResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.run(operation, on: window)) }
        }
    }

    public func perform(_ operation: WindowOperation, onApp app: AppEntry) async -> OperationResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.run(operation, onApp: app)) }
        }
    }

    private func run(_ operation: WindowOperation, on window: WindowEntry) -> OperationResult {
        guard accessibility.isTrusted() else { return .notPermitted }
        if operation == .quitApp, window.bundleIdentifier == Self.finderBundleIdentifier {
            return .refused("Finder can't be quit")
        }
        guard let app = runningApp(of: window) else { return .appGone }
        let (ref, pid) = (window.ref, window.pid)
        switch operation {
        case .focus:
            return focus(window, app: app)
        case .minimize:
            return attempt(on: window.owner, refusal: "can't be minimized") { () throws(AccessibilityFailure) in
                try accessibility.setMinimized(true, window: ref, pid: pid)
            }
        case .close:
            return attempt(on: window.owner, refusal: "can't be closed") { () throws(AccessibilityFailure) in
                try accessibility.pressCloseButton(ref, pid: pid)
            }
        case .hideApp:
            return hide(window.owner)
        case .quitApp:
            return delivered(apps.terminate(pid), to: window.owner, refusal: "did not quit")
        }
    }

    private func run(_ operation: WindowOperation, onApp app: AppEntry) -> OperationResult {
        guard accessibility.isTrusted() else { return .notPermitted }
        if operation == .quitApp, app.bundleIdentifier == Self.finderBundleIdentifier {
            return .refused("Finder can't be quit")
        }
        let owner = Owner(pid: app.pid, bundleIdentifier: app.bundleIdentifier)
        guard let state = runningApp(owner) else { return .appGone }
        switch operation {
        case .focus:
            if state.isHidden || app.isHidden, !apps.unhide(app.pid), runningApp(owner) == nil { return .appGone }
            return attempt(on: owner, refusal: "did not come to front") { () throws(AccessibilityFailure) in
                _ = apps.activate(app.pid)
                do throws(AccessibilityFailure) {
                    try Self.step { () throws(AccessibilityFailure) in try accessibility.makeFrontmost(pid: app.pid) }
                    if try readBack(nil, pid: app.pid) { return }
                } catch .invalidElement {
                    // There is no window to have gone; an app element that is invalid while the app runs is a refusal.
                    throw .failed
                }
                throw .failed
            }
        case .minimize, .close:
            return .refused("has no window")
        case .hideApp:
            return hide(owner)
        case .quitApp:
            return delivered(apps.terminate(app.pid), to: owner, refusal: "did not quit")
        }
    }

    private func hide(_ owner: Owner) -> OperationResult {
        // An app that is already hidden may not take the request; it is hidden all the same.
        if apps.hide(owner.pid) { return .done }
        guard let app = runningApp(owner) else { return .appGone }
        return app.isHidden ? .done : .refused("did not hide")
    }

    private func focus(_ window: WindowEntry, app: RunningAppState) -> OperationResult {
        let (ref, pid) = (window.ref, window.pid)
        // Unhiding an app that is not hidden changes nothing, so either report of hiding is enough.
        if app.isHidden || window.isAppHidden, !apps.unhide(pid), runningApp(of: window) == nil { return .appGone }
        return attempt(on: window.owner, refusal: "did not come to front") { () throws(AccessibilityFailure) in
            // A window without `kAXMinimized`, such as a dialog, cannot be minimized.
            if try Self.step({ () throws(AccessibilityFailure) in try accessibility.isMinimized(ref, pid: pid) }) == true {
                try Self.step { () throws(AccessibilityFailure) in try accessibility.setMinimized(false, window: ref, pid: pid) }
            }
            try Self.step { () throws(AccessibilityFailure) in try accessibility.raise(ref, pid: pid) }
            try Self.step { () throws(AccessibilityFailure) in try accessibility.makeMain(ref, pid: pid) }
            _ = apps.activate(pid)
            try Self.step { () throws(AccessibilityFailure) in try accessibility.makeFrontmost(pid: pid) }
            if try readBack(ref, pid: pid) { return }
            // The window may have closed while it was coming forward; one that still exists did not come forward.
            do throws(AccessibilityFailure) {
                try accessibility.probe(ref, pid: pid)
            } catch {
                if error == .invalidElement || error == .notPermitted { throw error }
            }
            throw .failed
        }
    }

    /// Reads back whether the app is frontmost and its focused window is the window (when there is one), until both
    /// are or `readBackTimeout` has passed. A background app's focused window can already be the window, so frontmost
    /// is read too. A read that fails because the app is slow or cannot say is retried until then. No read starts
    /// after the deadline, and a read that answers after it does not count, so focus is never confirmed late.
    private func readBack(_ window: WindowRef?, pid: pid_t) throws(AccessibilityFailure) -> Bool {
        let deadline = ContinuousClock.now + readBackTimeout
        while ContinuousClock.now < deadline {
            do throws(AccessibilityFailure) {
                if try accessibility.isFrontmost(pid: pid), ContinuousClock.now < deadline,
                   try window.map({ window throws(AccessibilityFailure) in try accessibility.isFocused(window, pid: pid) }) ?? true {
                    return ContinuousClock.now <= deadline
                }
            } catch {
                switch error {
                case .timedOut, .unsupported, .failed: break
                case .invalidElement, .notPermitted: throw error
                }
            }
            let left = deadline - .now
            guard left > .zero else { return false }
            Thread.sleep(forTimeInterval: Self.seconds(min(Self.readBackInterval, left)))
        }
        return false
    }

    /// Runs one focus step. A window or app that is gone, an app that does not answer, or lost trust ends the
    /// operation; a step the window does not support or that fails otherwise is skipped, and the read-back decides.
    /// Returns the step's answer, or nil when it was skipped.
    @discardableResult
    private static func step<Answer>(
        _ request: () throws(AccessibilityFailure) -> Answer
    ) throws(AccessibilityFailure) -> Answer? {
        do throws(AccessibilityFailure) {
            return try request()
        } catch {
            switch error {
            case .unsupported, .failed: return nil
            case .invalidElement, .timedOut, .notPermitted: throw error
            }
        }
    }

    private func attempt(
        on owner: Owner,
        refusal: String,
        _ requests: () throws(AccessibilityFailure) -> Void
    ) -> OperationResult {
        do throws(AccessibilityFailure) {
            try requests()
            return .done
        } catch {
            if error == .notPermitted { return .notPermitted }
            guard runningApp(owner) != nil else { return .appGone }
            switch error {
            case .invalidElement: return .windowGone
            case .timedOut: return .refused("not responding")
            case .unsupported, .failed, .notPermitted: return .refused(refusal)
            }
        }
    }

    private func delivered(_ sent: Bool, to owner: Owner, refusal: String) -> OperationResult {
        if sent { return .done }
        return runningApp(owner) == nil ? .appGone : .refused(refusal)
    }

    private func runningApp(of window: WindowEntry) -> RunningAppState? {
        runningApp(window.owner)
    }

    /// The app if it still runs. A different bundle ID at the same pid is another app that reused it.
    private func runningApp(_ owner: Owner) -> RunningAppState? {
        guard let app = apps.app(owner.pid), app.bundleIdentifier == owner.bundleIdentifier else { return nil }
        return app
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// The app an operation acts on, by pid and the bundle ID it had when listed.
private struct Owner {
    var pid: pid_t
    var bundleIdentifier: String?
}

private extension WindowEntry {
    var owner: Owner { Owner(pid: pid, bundleIdentifier: bundleIdentifier) }
}
