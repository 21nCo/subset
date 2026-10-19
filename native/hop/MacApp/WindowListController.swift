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
///
/// The keyboard tap runs on the main thread, so no Accessibility request to another app is made here except by
/// `refresh()`: seeding, observer registration and removal, and the reads that notifications trigger run on
/// `FocusTracker`'s own thread.
@MainActor
final class WindowListController {
    private let tracker = FocusTracker()
    private var workspaceObservers: [NSObjectProtocol] = []

    var isStarted: Bool { !workspaceObservers.isEmpty }

    /// Seeds the recency order and starts following focus changes. Call only while Hop is trusted.
    func start() {
        guard !isStarted else { return }
        let center = NSWorkspace.shared.notificationCenter
        let handlers: [(Notification.Name, @Sendable (FocusTracker, RunningApp) -> Void)] = [
            (NSWorkspace.didActivateApplicationNotification, { $0.appActivated($1) }),
            (NSWorkspace.didLaunchApplicationNotification, { $0.appLaunched($1) }),
            (NSWorkspace.didTerminateApplicationNotification, { $0.appTerminated($1) }),
        ]
        for (name, handle) in handlers {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [tracker] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                handle(tracker, RunningApp(app))
            })
        }
        tracker.start(
            apps: NSWorkspace.shared.runningApplications.map(RunningApp.init),
            frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    /// Stops following focus changes. The recency order is kept, and reseeded by the next `start()`.
    func stop() {
        guard isStarted else { return }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        tracker.stop()
    }

    /// Rebuilds the window list, most recently used first. It blocks the calling thread for at most
    /// `WindowLister.appBudget` plus `WindowLister.budgetGrace` (0.3 s) however many apps are slow, or up to twice
    /// that if it starts while the launch seed is reading the apps.
    @discardableResult
    func refresh() -> WindowList {
        tracker.refresh()
    }
}

/// What the tracker needs to know about an app from a workspace notification, read on the main thread.
struct RunningApp: Sendable {
    var pid: pid_t
    var isRegular: Bool

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        isRegular = app.activationPolicy == .regular && !app.isTerminated
    }
}

/// The recency order and the Accessibility observers that update it. Everything except `refresh()` and the lister
/// runs on `thread`, which also delivers the observers' callbacks, so the observer state needs no lock; the lister is
/// shared with `refresh()` behind `listerLock`, which serializes recency updates with refreshes.
final class FocusTracker: @unchecked Sendable {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "windows")
    private static let focusNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]

    private struct AppObserver {
        let observer: AXObserver
        var subscription = FocusSubscription(FocusTracker.focusNotifications)
        /// Whether the observer's run loop source is on `thread`'s run loop.
        var isScheduled = false
    }

    private let thread = AccessibilityThread(name: "\(HopIdentity.bundleIdentifier).accessibility")
    private let source = AXWindowSource()
    private let ownProcess = ProcessInfo.processInfo.processIdentifier
    private let listerLock = NSLock()
    private var lister: WindowLister

    // Owned by `thread`.
    private var observers: [pid_t: AppObserver] = [:]
    private var frontmost: pid_t?
    /// The retained reference the Accessibility callbacks receive while started; released by `stop()`, so a callback
    /// can never see a deallocated tracker.
    private var context: Unmanaged<FocusTracker>?

    init() {
        lister = WindowLister(source: source)
    }

    func start(apps: [RunningApp], frontmost: pid_t?) {
        thread.perform { [self] in
            guard context == nil else { return }
            context = Unmanaged.passRetained(self)
            self.frontmost = frontmost
            let onScreen = Self.onScreenOrder()
            report(listerLock.withLock { lister.seed(frontToBack: onScreen) }, seeded: true)
            apps.forEach(observe)
        }
    }

    func stop() {
        thread.perform { [self] in
            guard let context else { return }
            for pid in Array(observers.keys) { unobserve(pid) }
            context.release()
            self.context = nil
        }
    }

    func refresh() -> WindowList {
        let list = listerLock.withLock { lister.refresh() }
        report(list, seeded: false)
        return list
    }

    func appActivated(_ app: RunningApp) {
        thread.perform { [self] in
            guard context != nil else { return }
            frontmost = app.pid
            guard app.isRegular, app.pid != ownProcess else { return }
            // An app that was not ready when it launched, or did not answer every subscription, is observed once
            // it is active, and so answers.
            observe(app)
            let window = source.focusedWindow(of: app.pid)
            listerLock.withLock {
                if let window {
                    lister.noteFocused(source.ref(for: window, pid: app.pid), pid: app.pid)
                } else {
                    lister.noteActivated(pid: app.pid)
                }
            }
        }
    }

    func appLaunched(_ app: RunningApp) {
        thread.perform { [self] in observe(app) }
    }

    func appTerminated(_ app: RunningApp) {
        thread.perform { [self] in
            unobserve(app.pid)
            source.forgetApp(pid: app.pid)
            listerLock.withLock { lister.forgetApp(pid: app.pid) }
        }
    }

    /// A window of an observed app gained focus or became its app's main window. Only the frontmost app's changes
    /// count: a background app changing its own focus is not the user moving to it, and its activation, if it comes,
    /// reads the focused window then.
    fileprivate func windowFocused(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard context != nil, AXUIElementGetPid(element, &pid) == .success, pid == frontmost else { return }
        var role: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, AXWindowSource.messagingTimeout)
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        // Some apps report the change on the application element; read its focused window instead.
        let window = (role as? String) == kAXApplicationRole ? source.focusedWindow(of: pid) : element
        guard let window else { return }
        listerLock.withLock { lister.noteFocused(source.ref(for: window, pid: pid), pid: pid) }
    }

    // MARK: - Accessibility observers

    /// Subscribes to the app's focus notifications that it has not accepted yet.
    private func observe(_ app: RunningApp) {
        let pid = app.pid
        guard let context, app.isRegular, pid != ownProcess else { return }
        var entry: AppObserver
        if let existing = observers[pid] {
            entry = existing
        } else {
            var created: AXObserver?
            guard AXObserverCreate(pid, accessibilityCallback, &created) == .success, let created else { return }
            entry = AppObserver(observer: created)
        }
        guard !entry.subscription.isComplete else { return }
        let observer = entry.observer
        let element = AXWindowSource.appElement(pid)
        entry.subscription.register { notification in
            switch AXObserverAddNotification(observer, element, notification as CFString, context.toOpaque()) {
            case .success, .notificationAlreadyRegistered: .registered
            case .notificationUnsupported: .unsupported
            default: .unanswered
            }
        }
        if !entry.isScheduled, !entry.subscription.registered.isEmpty {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            entry.isScheduled = true
        }
        observers[pid] = entry
    }

    private func unobserve(_ pid: pid_t) {
        guard let entry = observers.removeValue(forKey: pid) else { return }
        // Removing a notification is a local call once the app has quit; for a running app it is one more request.
        let element = AXWindowSource.appElement(pid)
        for notification in entry.subscription.registered {
            AXObserverRemoveNotification(entry.observer, element, notification as CFString)
        }
        if entry.isScheduled {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(entry.observer), .defaultMode)
        }
    }

    // MARK: - Helpers

    /// The window server's on-screen windows, front to back. Reads owners, layers and bounds only.
    private static func onScreenOrder() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return OnScreenWindow.frontToBack(windowInfo: info)
    }

    private func report(_ list: WindowList, seeded: Bool) {
        let total = listerLock.withLock { lister.skippedAppCount }
        Self.log.debug("""
            Window list \(seeded ? "seeded" : "refreshed", privacy: .public): \(list.windows.count, privacy: .public) \
            windows, \(list.windowlessApps.count, privacy: .public) windowless apps, \
            \(list.skippedApps.count, privacy: .public) apps skipped (\(total, privacy: .public) since launch)
            """)
    }
}

/// The observers' C callback. Their run loop sources are on the tracker's thread, so this runs there.
private func accessibilityCallback(
    _: AXObserver,
    _ element: AXUIElement,
    _: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue().windowFocused(element)
}

/// A thread that runs its own run loop and performs the blocks it is given, in order. It lives as long as the app.
final class AccessibilityThread: @unchecked Sendable {
    private let runLoop: CFRunLoop

    init(name: String) {
        final class Started: @unchecked Sendable {
            var runLoop: CFRunLoop?
        }
        let started = Started()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            started.runLoop = CFRunLoopGetCurrent()
            // A port keeps the run loop running while it has no other source.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = started.runLoop!
    }

    /// Runs `work` on the thread after the blocks given before it.
    func perform(_ work: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }
}
