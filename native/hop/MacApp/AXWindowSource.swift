import AppKit
import ApplicationServices
import HopCore

/// Reads windows through the public Accessibility API: for each running app with the `.regular` activation policy,
/// its `kAXWindowsAttribute`, then each window's title, subrole, minimized state, position, size and `AXFullScreen` in
/// one request. Every request to an app gives up after `messagingTimeout`; an app that times out or fails is reported
/// as such and `WindowLister` leaves it out of that refresh.
///
/// Window refs (`HopCore.WindowRef`; Carbon has a type of the same name) are assigned here: a window keeps its ref
/// for as long as Accessibility reports an equal element for it. Refs are kept per app and replaced with each successful read of that app, so a closed window's ref is dropped
/// the next time its app is read, and all of an app's refs when it quits.
///
/// `apps()` and `displays()` read AppKit and CoreGraphics and run on the main thread; `windows(of:)` sends only
/// Accessibility requests and may run on any thread.
final class AXWindowSource: WindowSource, @unchecked Sendable {
    /// Seconds an app may take to answer one request before it is skipped.
    static let messagingTimeout: Float = 0.25

    private static let windowAttributes = [
        kAXTitleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute,
        "AXFullScreen"
    ]

    private let lock = NSLock()
    /// Each app's windows and their refs, from its last successful read or a later focus change.
    private var refs: [pid_t: [ElementKey: HopCore.WindowRef]] = [:]
    private var lastRef: UInt64 = 0

    func apps() -> [SourceApp] {
        MainActor.assumeIsolated {
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated
            }
            let live = Set(running.map(\.processIdentifier))
            lock.withLock { refs = refs.filter { live.contains($0.key) } }
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
    }

    func displays() -> [SourceDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { SourceDisplay(id: $0, bounds: CGDisplayBounds($0)) }
    }

    func windows(of app: SourceApp) throws(WindowSourceError) -> [SourceWindow] {
        let element = Self.appElement(app.pid)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) {
        case .success: break
        // An app with no windows may report no value rather than an empty list.
        case .noValue: return replaceRefs(of: app.pid, with: [:], returning: [])
        case .cannotComplete: throw .timedOut
        default: throw .failed
        }
        guard let elements = value as? [AXUIElement] else { throw .failed }

        let attributes = Self.windowAttributes as CFArray
        var windows: [SourceWindow] = []
        var appRefs: [ElementKey: HopCore.WindowRef] = [:]
        for window in elements {
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            var values: CFArray?
            switch AXUIElementCopyMultipleAttributeValues(window, attributes, AXCopyMultipleAttributeOptions(), &values) {
            case .success: break
            case .cannotComplete: throw .timedOut
            // The window closed between the two requests, or cannot be read; the app's other windows still can.
            default: continue
            }
            guard let read = values as? [CFTypeRef], read.count == Self.windowAttributes.count else { continue }
            let key = ElementKey(window)
            let ref = appRefs[key] ?? self.ref(for: key, pid: app.pid)
            appRefs[key] = ref
            windows.append(SourceWindow(
                ref: ref,
                title: read[0] as? String ?? "",
                subrole: read[1] as? String,
                isMinimized: read[2] as? Bool ?? false,
                isFullscreen: read[5] as? Bool ?? false,
                frame: Self.frame(position: read[3], size: read[4])
            ))
        }
        return replaceRefs(of: app.pid, with: appRefs, returning: windows)
    }

    /// The ref for a window element that a focus change reported, assigning a new one if it was never read.
    func ref(for window: AXUIElement, pid: pid_t) -> HopCore.WindowRef {
        ref(for: ElementKey(window), pid: pid)
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
        lock.withLock { _ = refs.removeValue(forKey: pid) }
    }

    /// An app's Accessibility element, with the per-app messaging timeout.
    static func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private func ref(for key: ElementKey, pid: pid_t) -> HopCore.WindowRef {
        lock.withLock {
            if let ref = refs[pid]?[key] { return ref }
            lastRef += 1
            let ref = HopCore.WindowRef(rawValue: lastRef)
            refs[pid, default: [:]][key] = ref
            return ref
        }
    }

    private func replaceRefs(
        of pid: pid_t,
        with appRefs: [ElementKey: HopCore.WindowRef],
        returning windows: [SourceWindow]
    ) -> [SourceWindow] {
        lock.withLock { refs[pid] = appRefs }
        return windows
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
