import Foundation

/// An action on a listed window or its app. The switcher's keys call these (SET-94); there is no batch operation.
public enum WindowOperation: Sendable, Equatable, CaseIterable {
    /// Bring the window to the front and give it focus: the switch itself.
    case focus
    case minimize
    /// Press the window's close button. An app that asks to save keeps its prompt: Hop never answers it.
    case close
    /// Hide the window's app (⌘H).
    case hideApp
    /// Ask the window's app to quit normally; it may prompt. Hop never force-quits, and never quits Finder.
    case quitApp
}

/// What an operation did, so the switcher can show a failure instead of silently doing nothing.
public enum OperationResult: Sendable, Equatable {
    /// The operation was carried out. A close that made the app show a save prompt is done too.
    case done
    /// The window no longer exists; its app is still running.
    case windowGone
    /// The window's app has exited.
    case appGone
    /// The app or system did not do it. The reason is short, user-facing, and never contains a window title.
    case refused(String)
    /// Hop does not hold the Accessibility permission. Nothing was attempted.
    case notPermitted
}

/// Performs operations on listed windows. `AccessibilityWindowOperator` is the implementation; the host's
/// `AXWindowOperator` gives it the live Accessibility and app adapters, and `RecordingWindowOperator` stands in for it
/// in tests of its callers.
public protocol WindowOperator: Sendable {
    /// Performs the operation away from the calling thread and returns its result; the caller, such as the switcher on
    /// the main thread, is never blocked while the app answers.
    func perform(_ operation: WindowOperation, on window: WindowEntry) async -> OperationResult
}

/// Records each operation it is asked to perform and answers with a fixed result per operation (`.done` unless set),
/// for tests of the switcher.
public final class RecordingWindowOperator: WindowOperator, @unchecked Sendable {
    public struct Call: Sendable, Equatable {
        public var operation: WindowOperation
        public var window: WindowRef
        public var pid: pid_t
    }

    private let lock = NSLock()
    private var results: [WindowOperation: OperationResult]
    private var recorded: [Call] = []

    public init(results: [WindowOperation: OperationResult] = [:]) {
        self.results = results
    }

    /// The operations performed so far, in the order they were asked for.
    public var calls: [Call] {
        lock.withLock { recorded }
    }

    public func setResult(_ result: OperationResult, for operation: WindowOperation) {
        lock.withLock { results[operation] = result }
    }

    public func perform(_ operation: WindowOperation, on window: WindowEntry) async -> OperationResult {
        lock.withLock {
            recorded.append(Call(operation: operation, window: window.ref, pid: window.pid))
            return results[operation] ?? .done
        }
    }
}
