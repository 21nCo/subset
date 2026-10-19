import AppKit
import ApplicationServices
import HopCore

/// Reads windows through the public Accessibility API: for each running app with the `.regular` activation policy,
/// its `kAXWindowsAttribute`, then each window's title, subrole, minimized state, position, size and `AXFullScreen` in
/// one request. Each app's read has one deadline, `WindowLister.appBudget` (0.25 s) from the start of the refresh:
/// before every request the messaging timeout (`AXUIElementSetMessagingTimeout`) is set to the time left, so an app
/// with many slow windows costs the budget, not a timeout per window. An app that runs out of time or fails is
/// reported as such and `WindowLister` leaves it out of that refresh.
///
/// Window refs (`HopCore.WindowRef`; Carbon has a type of the same name) are kept in a `WindowRefRegistry` keyed by
/// window element: a window keeps its ref for as long as Accessibility reports an equal element for it, even when a
/// focus change or a read that overran its refresh completes in between. A closed window's ref is dropped by the next
/// completed read of its app, and all of an app's refs when it quits.
///
/// Every method may run on any thread: `apps()` reads `NSWorkspace.runningApplications` and `NSRunningApplication`,
/// which return their values atomically on any thread, and `windows(of:until:)` sends only Accessibility requests.
final class AXWindowSource: WindowSource, @unchecked Sendable {
    /// Seconds an app may take to answer a request outside a refresh, such as reading its focused window.
    static let messagingTimeout = Float(WindowLister.defaultAppBudget / .seconds(1))

    private static let windowAttributes = [
        kAXTitleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute,
        "AXFullScreen"
    ]

    private let lock = NSLock()
    private var registry = WindowRefRegistry<ElementKey>()

    func apps() -> [SourceApp] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let live = Set(running.map(\.processIdentifier))
        lock.withLock { registry.retainApps(live) }
        return running.map { app in
            SourceApp(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "",
                activationPolicy: .regular,
                isHidden: app.isHidden
            )
        }
    }

    func displays() -> [SourceDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { SourceDisplay(id: $0, bounds: CGDisplayBounds($0)) }
    }

    func windows(of app: SourceApp, until deadline: ContinuousClock.Instant) throws(WindowSourceError) -> [SourceWindow] {
        var read = lock.withLock { registry.beginRead(of: app.pid) }
        let element = AXUIElementCreateApplication(app.pid)
        try Self.limit(element, to: deadline)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) {
        case .success: break
        // An app with no windows may report no value rather than an empty list.
        case .noValue:
            lock.withLock { registry.commit(read) }
            return []
        case .cannotComplete: throw .timedOut
        default: throw .failed
        }
        guard let elements = value as? [AXUIElement] else { throw .failed }

        let attributes = Self.windowAttributes as CFArray
        var windows: [SourceWindow] = []
        for window in elements {
            try Self.limit(window, to: deadline)
            var values: CFArray?
            switch AXUIElementCopyMultipleAttributeValues(window, attributes, AXCopyMultipleAttributeOptions(), &values) {
            case .success: break
            case .cannotComplete: throw .timedOut
            // The window closed between the two requests, or cannot be read; the app's other windows still can.
            default: continue
            }
            guard let fields = values as? [CFTypeRef], fields.count == Self.windowAttributes.count else { continue }
            let ref = lock.withLock { registry.ref(for: ElementKey(window), in: &read) }
            windows.append(SourceWindow(
                ref: ref,
                title: fields[0] as? String ?? "",
                subrole: fields[1] as? String,
                isMinimized: fields[2] as? Bool ?? false,
                isFullscreen: fields[5] as? Bool ?? false,
                frame: Self.frame(position: fields[3], size: fields[4])
            ))
        }
        lock.withLock { registry.commit(read) }
        return windows
    }

    /// The ref for a window element that a focus change reported, assigning a new one if it was never read.
    func ref(for window: AXUIElement, pid: pid_t) -> HopCore.WindowRef {
        lock.withLock { registry.ref(for: ElementKey(window), pid: pid) }
    }

    /// The app's focused window, or nil if it has none or did not answer in time.
    func focusedWindow(of pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(Self.appElement(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// Forgets the refs of an app that quit.
    func forgetApp(pid: pid_t) {
        lock.withLock { registry.forgetApp(pid: pid) }
    }

    /// An app's Accessibility element, with the per-app messaging timeout.
    static func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Gives the element's next request the time left until `deadline`, or throws `.timedOut` when none is left.
    private static func limit(_ element: AXUIElement, to deadline: ContinuousClock.Instant) throws(WindowSourceError) {
        let left = deadline - .now
        // A timeout of zero would restore the system default, so an exhausted budget never reaches the call.
        guard left > .zero else { throw .timedOut }
        AXUIElementSetMessagingTimeout(element, Float(left / .seconds(1)))
    }

    private static func frame(position: CFTypeRef, size: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

/// An Accessibility element as a dictionary key: two elements for the same window compare equal with `CFEqual`.
private struct ElementKey: Hashable, @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: ElementKey, rhs: ElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
