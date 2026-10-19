import AppKit
import ApplicationServices
import HopCore
import os

/// Keeps the window list's recency order current while Hop has the Accessibility permission, and rebuilds the list
/// on `refresh()`, which the switcher calls when it opens (SET-94).
///
/// `start()` seeds the order from the window server's front-to-back order (`CGWindowListCopyWindowInfo`, matched to
/// windows by owner and frame; window names are never read). From then on an app's activation
/// (`NSWorkspace.didActivateApplicationNotification`) brings its focused window to the front, and so does a focus or
/// main-window change in the frontmost app (`kAXFocusedWindowChangedNotification`, `kAXMainWindowChangedNotification`,
/// observed per app). Only counts are logged, never a title.
@MainActor
final class WindowListController {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "windows")
    private static let focusNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]

    private let source = AXWindowSource()
    private var lister: WindowLister
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [pid_t: AXObserver] = [:]
    /// The retained reference the Accessibility callbacks receive while started; released by `stop()`, so a callback
    /// can never see a deallocated controller.
    private var context: Unmanaged<WindowListController>?

    init() {
        lister = WindowLister(source: source)
    }

    var isStarted: Bool { context != nil }

    /// Seeds the recency order and starts following focus changes. Call only while Hop is trusted.
    func start() {
        guard context == nil else { return }
        context = Unmanaged.passRetained(self)
        let center = NSWorkspace.shared.notificationCenter
        let handlers: [(Notification.Name, @MainActor @Sendable (WindowListController, NSRunningApplication) -> Void)] = [
            (NSWorkspace.didActivateApplicationNotification, { $0.appActivated($1) }),
            (NSWorkspace.didLaunchApplicationNotification, { $0.observe($1) }),
            (NSWorkspace.didTerminateApplicationNotification, { $0.appTerminated($1) }),
        ]
        for (name, handle) in handlers {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, let app else { return }
                    handle(self, app)
                }
            })
        }
        NSWorkspace.shared.runningApplications.forEach(observe)
        report(lister.seed(frontToBack: Self.onScreenOrder()), seeded: true)
    }

    /// Stops following focus changes. The recency order is kept, and reseeded by the next `start()`.
    func stop() {
        guard let context else { return }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        for pid in Array(appObservers.keys) { unobserve(pid) }
        context.release()
        self.context = nil
    }

    /// Rebuilds the window list, most recently used first.
    @discardableResult
    func refresh() -> WindowList {
        let list = lister.refresh()
        report(list, seeded: false)
        return list
    }

    // MARK: - Recency

    private func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != lister.ownProcess, app.activationPolicy == .regular else { return }
        // An app that was not ready when it launched is observed once it is active, and so answers.
        observe(app)
        if let window = source.focusedWindow(of: pid) {
            lister.noteFocused(source.ref(for: window, pid: pid), pid: pid)
        } else {
            lister.noteActivated(pid: pid)
        }
    }

    private func appTerminated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        unobserve(pid)
        source.forgetApp(pid: pid)
        lister.forgetApp(pid: pid)
    }

    /// A window of an observed app gained focus or became its app's main window. Only the frontmost app's changes
    /// count: a background app changing its own focus is not the user moving to it, and its activation, if it comes,
    /// reads the focused window then.
    fileprivate func windowFocused(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { return }
        var role: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, AXWindowSource.messagingTimeout)
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        // Some apps report the change on the application element; read its focused window instead.
        let window = (role as? String) == kAXApplicationRole ? source.focusedWindow(of: pid) : element
        guard let window else { return }
        lister.noteFocused(source.ref(for: window, pid: pid), pid: pid)
    }

    // MARK: - Accessibility observers

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard let context, appObservers[pid] == nil, app.activationPolicy == .regular, pid != lister.ownProcess,
              !app.isTerminated
        else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, accessibilityCallback, &created) == .success, let observer = created else { return }
        let element = AXWindowSource.appElement(pid)
        var added = false
        for notification in Self.focusNotifications {
            let result = AXObserverAddNotification(observer, element, notification as CFString, context.toOpaque())
            // An app that does not answer is tried again when it is next activated.
            if result == .cannotComplete { break }
            added = added || result == .success || result == .notificationAlreadyRegistered
        }
        guard added else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        appObservers[pid] = observer
    }

    private func unobserve(_ pid: pid_t) {
        guard let observer = appObservers.removeValue(forKey: pid) else { return }
        // Removing a notification is a local call once the app has quit; for a running app it is one more request.
        let element = AXWindowSource.appElement(pid)
        for notification in Self.focusNotifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    // MARK: - Helpers

    /// The window server's on-screen windows, front to back. Reads owners, layers and bounds only.
    private static func onScreenOrder() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return OnScreenWindow.frontToBack(windowInfo: info)
    }

    private func report(_ list: WindowList, seeded: Bool) {
        Self.log.debug("""
            Window list \(seeded ? "seeded" : "refreshed", privacy: .public): \(list.windows.count, privacy: .public) \
            windows, \(list.windowlessApps.count, privacy: .public) windowless apps, \
            \(list.skippedApps.count, privacy: .public) apps skipped (\(self.lister.skippedAppCount, privacy: .public) \
            since launch)
            """)
    }
}

/// The observers' C callback. Their run loop sources are on the main run loop, so this runs on the main thread.
private func accessibilityCallback(
    _: AXObserver,
    _ element: AXUIElement,
    _: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let controller = Unmanaged<WindowListController>.fromOpaque(refcon).takeUnretainedValue()
    nonisolated(unsafe) let element = element
    MainActor.assumeIsolated { controller.windowFocused(element) }
}
