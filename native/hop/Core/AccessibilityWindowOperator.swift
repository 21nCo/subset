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
    /// Whether the app's `kAXFocusedWindow` is the window; false when the app has no focused window.
    func isFocused(_ window: WindowRef, pid: pid_t) throws(AccessibilityFailure) -> Bool
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
/// is skipped, and a window whose minimized state cannot be read is taken as not minimized. It succeeds when the app's
/// focused window reads back as this window within `readBackTimeout` (0.5 s), and is otherwise
/// `.refused("did not come to front")`. **minimize** sets `kAXMinimized` true. **close** presses the close button and
/// is done even if the app then asks to save: Hop leaves that prompt to the user. **hideApp** hides the app, and is
/// done when it was hidden already. **quitApp** asks the app to quit normally, never by force, and Finder is never
/// quit.
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
            return attempt(on: window, refusal: "can't be minimized") { () throws(AccessibilityFailure) in
                try accessibility.setMinimized(true, window: ref, pid: pid)
            }
        case .close:
            return attempt(on: window, refusal: "can't be closed") { () throws(AccessibilityFailure) in
                try accessibility.pressCloseButton(ref, pid: pid)
            }
        case .hideApp:
            // An app that is already hidden may not take the request; it is hidden all the same.
            if apps.hide(pid) { return .done }
            guard let app = runningApp(of: window) else { return .appGone }
            return app.isHidden ? .done : .refused("did not hide")
        case .quitApp:
            return delivered(apps.terminate(pid), to: window, refusal: "did not quit")
        }
    }

    private func focus(_ window: WindowEntry, app: RunningAppState) -> OperationResult {
        let (ref, pid) = (window.ref, window.pid)
        // Unhiding an app that is not hidden changes nothing, so either report of hiding is enough.
        if app.isHidden || window.isAppHidden, !apps.unhide(pid), runningApp(of: window) == nil { return .appGone }
        return attempt(on: window, refusal: "did not come to front") { () throws(AccessibilityFailure) in
            // A window without `kAXMinimized`, such as a dialog, cannot be minimized.
            if try Self.step({ () throws(AccessibilityFailure) in try accessibility.isMinimized(ref, pid: pid) }) == true {
                try Self.step { () throws(AccessibilityFailure) in try accessibility.setMinimized(false, window: ref, pid: pid) }
            }
            try Self.step { () throws(AccessibilityFailure) in try accessibility.raise(ref, pid: pid) }
            try Self.step { () throws(AccessibilityFailure) in try accessibility.makeMain(ref, pid: pid) }
            _ = apps.activate(pid)
            try Self.step { () throws(AccessibilityFailure) in try accessibility.makeFrontmost(pid: pid) }
            guard try readBack(ref, pid: pid) else { throw .failed }
        }
    }

    /// Reads the app's focused window until it is the window or `readBackTimeout` has passed. A read that fails
    /// because the app is slow or cannot say is retried until then. No read starts after the deadline, and a read
    /// that answers after it does not count, so focus is never confirmed late.
    private func readBack(_ window: WindowRef, pid: pid_t) throws(AccessibilityFailure) -> Bool {
        let deadline = ContinuousClock.now + readBackTimeout
        while ContinuousClock.now < deadline {
            do throws(AccessibilityFailure) {
                if try accessibility.isFocused(window, pid: pid) { return ContinuousClock.now <= deadline }
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
        on window: WindowEntry,
        refusal: String,
        _ requests: () throws(AccessibilityFailure) -> Void
    ) -> OperationResult {
        do throws(AccessibilityFailure) {
            try requests()
            return .done
        } catch {
            if error == .notPermitted { return .notPermitted }
            guard runningApp(of: window) != nil else { return .appGone }
            switch error {
            case .invalidElement: return .windowGone
            case .timedOut: return .refused("not responding")
            case .unsupported, .failed, .notPermitted: return .refused(refusal)
            }
        }
    }

    private func delivered(_ sent: Bool, to window: WindowEntry, refusal: String) -> OperationResult {
        if sent { return .done }
        return runningApp(of: window) == nil ? .appGone : .refused(refusal)
    }

    /// The window's app if it still runs. A different bundle ID at the same pid is another app that reused it.
    private func runningApp(of window: WindowEntry) -> RunningAppState? {
        guard let app = apps.app(window.pid), app.bundleIdentifier == window.bundleIdentifier else { return nil }
        return app
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
