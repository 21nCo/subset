import AppKit
import ApplicationServices
import HopCore

/// The live window operator: `AccessibilityWindowOperator` with requests sent through the public Accessibility API and
/// `NSRunningApplication`. Windows are reached through the elements `AXWindowSource` keeps for their refs, so an
/// operation acts on the window the list showed, and a ref whose window a read found closed is `.windowGone`.
///
/// Operations run on the operator's own queue, never on the main thread; every Accessibility request has the 0.25 s
/// messaging timeout (`AXWindowSource.messagingTimeout`). Nothing about a window, and never a title, is logged.
final class AXWindowOperator: WindowOperator {
    private let operations: AccessibilityWindowOperator

    init(source: AXWindowSource) {
        operations = AccessibilityWindowOperator(accessibility: AXWindowAccessibility(source: source), apps: RunningAppControl())
    }

    func perform(_ operation: WindowOperation, on window: WindowEntry) async -> OperationResult {
        await operations.perform(operation, on: window)
    }
}

/// Accessibility requests on a listed window or its app.
private struct AXWindowAccessibility: WindowAccessibility {
    let source: AXWindowSource

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func isMinimized(_ window: HopCore.WindowRef, pid: pid_t) throws(AccessibilityFailure) -> Bool {
        guard let minimized = try copy(kAXMinimizedAttribute, of: element(window, pid: pid)) as? Bool else {
            throw .unsupported
        }
        return minimized
    }

    func setMinimized(_ minimized: Bool, window: HopCore.WindowRef, pid: pid_t) throws(AccessibilityFailure) {
        try set(kAXMinimizedAttribute, of: element(window, pid: pid), to: minimized)
    }

    func raise(_ window: HopCore.WindowRef, pid: pid_t) throws(AccessibilityFailure) {
        try check(AXUIElementPerformAction(element(window, pid: pid), kAXRaiseAction as CFString))
    }

    func makeMain(_ window: HopCore.WindowRef, pid: pid_t) throws(AccessibilityFailure) {
        try set(kAXMainAttribute, of: element(window, pid: pid), to: true)
    }

    func pressCloseButton(_ window: HopCore.WindowRef, pid: pid_t) throws(AccessibilityFailure) {
        let button = try copy(kAXCloseButtonAttribute, of: element(window, pid: pid))
        guard CFGetTypeID(button) == AXUIElementGetTypeID() else { throw .unsupported }
        let element = button as! AXUIElement
        AXUIElementSetMessagingTimeout(element, AXWindowSource.messagingTimeout)
        try check(AXUIElementPerformAction(element, kAXPressAction as CFString))
    }

    func makeFrontmost(pid: pid_t) throws(AccessibilityFailure) {
        try set(kAXFrontmostAttribute, of: AXWindowSource.appElement(pid), to: true)
    }

    func isFrontmost(pid: pid_t) throws(AccessibilityFailure) -> Bool {
        guard let frontmost = try copy(kAXFrontmostAttribute, of: AXWindowSource.appElement(pid)) as? Bool else {
            throw .unsupported
        }
        return frontmost
    }

    func isFocused(_ window: HopCore.WindowRef, pid: pid_t) throws(AccessibilityFailure) -> Bool {
        let target = try element(window, pid: pid)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(AXWindowSource.appElement(pid), kAXFocusedWindowAttribute as CFString, &value) {
        // An app with no focused window may report no value.
        case .noValue: return false
        case let error: try check(error)
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return CFEqual(value, target)
    }

    func probe(_ window: HopCore.WindowRef, pid: pid_t) throws(AccessibilityFailure) {
        _ = try copy(kAXRoleAttribute, of: element(window, pid: pid))
    }

    /// The window's element with the messaging timeout set, or `.invalidElement` when its ref is no longer kept. The
    /// element is shared with the source, which may have given it a shorter timeout or none, so it is set every time.
    private func element(_ window: HopCore.WindowRef, pid: pid_t) throws(AccessibilityFailure) -> AXUIElement {
        guard let element = source.element(for: window, pid: pid) else { throw .invalidElement }
        AXUIElementSetMessagingTimeout(element, AXWindowSource.messagingTimeout)
        return element
    }

    private func copy(_ attribute: String, of element: AXUIElement) throws(AccessibilityFailure) -> CFTypeRef {
        var value: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(element, attribute as CFString, &value))
        guard let value else { throw .unsupported }
        return value
    }

    private func set(_ attribute: String, of element: AXUIElement, to value: Bool) throws(AccessibilityFailure) {
        try check(AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean))
    }

    private func check(_ error: AXError) throws(AccessibilityFailure) {
        switch error {
        case .success: return
        case .invalidUIElement: throw .invalidElement
        case .cannotComplete: throw .timedOut
        case .apiDisabled: throw .notPermitted
        case .attributeUnsupported, .actionUnsupported, .noValue, .notImplemented: throw .unsupported
        default: throw .failed
        }
    }
}

/// App requests through `NSRunningApplication`, which may be used from any thread. A fresh instance is looked up for
/// every request, so an app that exited is never acted on.
private struct RunningAppControl: AppControl {
    func app(_ pid: pid_t) -> RunningAppState? {
        running(pid).map { RunningAppState(bundleIdentifier: $0.bundleIdentifier, isHidden: $0.isHidden) }
    }

    func unhide(_ pid: pid_t) -> Bool {
        running(pid)?.unhide() ?? false
    }

    func activate(_ pid: pid_t) -> Bool {
        // No options: only the window just made main comes forward, not every window of the app.
        running(pid)?.activate(options: []) ?? false
    }

    func hide(_ pid: pid_t) -> Bool {
        running(pid)?.hide() ?? false
    }

    func terminate(_ pid: pid_t) -> Bool {
        running(pid)?.terminate() ?? false
    }

    private func running(_ pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return app
    }
}
