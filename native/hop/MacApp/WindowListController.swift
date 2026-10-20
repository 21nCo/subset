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
/// `refresh()`: seeding and the reads that notifications trigger run on `FocusTracker`'s own thread, and subscribing
/// to and removing the notifications on a worker queue.
@MainActor
final class WindowListController {
    private let tracker: FocusTracker
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Acts on the listed windows; the switcher calls it (SET-94). It reaches windows through the same source as the
    /// list, so a listed window's ref names the window the list showed.
    let windowOperator: any WindowOperator

    init() {
        let source = AXWindowSource()
        tracker = FocusTracker(source: source)
        windowOperator = AXWindowOperator(source: source)
    }

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

/// The recency order and the Accessibility observers that update it. Everything except `refresh()`, the lister and
/// the subscription requests runs on `thread`, which also delivers the observers' callbacks, so the observer state
/// needs no lock; the lister is shared with `refresh()` behind `listerLock`, which serializes recency updates with
/// refreshes. Adding and removing notifications are requests to the app, which may not answer for the messaging
/// timeout, so they run on `registrar`, each app's at once, and `observers` decides on `thread` what their results
/// still mean.
final class FocusTracker: @unchecked Sendable {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "windows")
    private static let focusNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]

    private let thread = AccessibilityThread(name: "\(HopIdentity.bundleIdentifier).accessibility")
    private let registrar = DispatchQueue(
        label: "\(HopIdentity.bundleIdentifier).accessibility.subscriptions",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let source: AXWindowSource
    private let ownProcess = ProcessInfo.processInfo.processIdentifier
    private let listerLock = NSLock()
    private var lister: WindowLister

    // Owned by `thread`.
    private var observers = FocusObservers<AXObserver>(FocusTracker.focusNotifications)
    private var frontmost: pid_t?
    /// The retained reference the Accessibility callbacks receive while started; released by `stop()`, so a callback
    /// can never see a deallocated tracker.
    private var context: Unmanaged<FocusTracker>?

    init(source: AXWindowSource) {
        self.source = source
        lister = WindowLister(source: source)
    }

    func start(apps: [RunningApp], frontmost: pid_t?) {
        thread.perform { [self] in
            guard context == nil else { return }
            context = Unmanaged.passRetained(self)
            self.frontmost = frontmost
            // Subscribing first narrows the time a focus change goes unreported; the frontmost app's focus is read
            // again once its observer is scheduled, after the seed (see `subscribed(_:)`).
            apps.forEach(observe)
            let onScreen = Self.onScreenOrder()
            report(listerLock.withLock { lister.seed(frontToBack: onScreen) }, seeded: true)
        }
    }

    func stop() {
        thread.perform { [self] in
            guard let context else { return }
            observers.removeAll().forEach(release)
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

    /// Subscribes, on `registrar`, to the app's focus notifications that it has not accepted yet.
    private func observe(_ app: RunningApp) {
        let pid = app.pid
        guard context != nil, app.isRegular, pid != ownProcess else { return }
        let round = observers.begin(pid: pid) {
            var created: AXObserver?
            return AXObserverCreate(pid, accessibilityCallback, &created) == .success ? created : nil
        }
        guard let round else { return }
        let pending = Unchecked(round)
        registrar.async { [self] in
            var round = pending.value
            let element = AXWindowSource.appElement(pid)
            // The callbacks' refcon: the reference `start()` retained, released only after `stop()` has removed every
            // scheduled source, and a discarded round's source is never scheduled.
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            round.subscription.register { notification in
                switch AXObserverAddNotification(round.observer, element, notification as CFString, refcon) {
                case .success, .notificationAlreadyRegistered: .registered
                case .notificationUnsupported: .unsupported
                default: .unanswered
                }
            }
            let finished = Unchecked(round)
            thread.perform { [self] in subscribed(finished.value) }
        }
    }

    /// An app answered a round of subscriptions, or ran out of time.
    private func subscribed(_ round: FocusObservers<AXObserver>.Registration) {
        switch observers.finish(round) {
        case let .discarded(removed):
            release(removed)
        case .kept(firstScheduled: false):
            break
        case .kept(firstScheduled: true):
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(round.observer), .defaultMode)
            // The focus may have changed before the observer could report it, such as during the launch seed.
            if round.pid == frontmost, let window = source.focusedWindow(of: round.pid) {
                listerLock.withLock { lister.noteFocused(source.ref(for: window, pid: round.pid), pid: round.pid) }
            }
        }
    }

    private func unobserve(_ pid: pid_t) {
        guard let removed = observers.remove(pid: pid) else { return }
        release(removed)
    }

    /// Takes the observer's source off `thread`'s run loop now, and removes its notifications on `registrar`.
    /// Removing a notification is a local call once the app has quit; for a running app it is one more request.
    private func release(_ removed: FocusObservers<AXObserver>.Removed) {
        if removed.isScheduled {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(removed.observer), .defaultMode)
        }
        guard !removed.notifications.isEmpty else { return }
        let pending = Unchecked(removed)
        registrar.async {
            let element = AXWindowSource.appElement(pending.value.pid)
            for notification in pending.value.notifications {
                AXObserverRemoveNotification(pending.value.observer, element, notification as CFString)
            }
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

/// A value handed between `FocusTracker`'s thread and its worker queue, which never use it at the same time.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
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
