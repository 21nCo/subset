import AppKit
import PointInTimeCore

/// Wires macOS signals to the capture session and the store. Samples every few seconds while tracking is allowed;
/// `CaptureSession` decides when capture stops (sleep, lock, fast user switching, idle, pause, tracking off, a write
/// backlog, or a clock behind recorded activity) and what is saved.
@MainActor
final class CaptureController {
    static let sampleInterval: TimeInterval = 5

    var state: CaptureState { session.state }
    /// A store write that has not succeeded yet, why the store could not be read, or why it could not be opened. A
    /// failed write stays queued and is retried on every tick, and the error stays visible until the queue drains.
    var lastError: String? { session.writes.failure ?? session.readError ?? storeError }
    /// Whether a deletion or idle retraction has not succeeded yet. The queue lives in memory, so quitting cancels it.
    var hasPendingDeletion: Bool { session.writes.hasPendingDeletion }
    /// Whether recorded activity has not been saved yet. The queue lives in memory, so quitting discards it.
    var hasUnsavedActivity: Bool { session.writes.hasPendingSave }
    /// The most recent foreground app other than pointInTime, offered by the menu's Exclude action. Kept current while
    /// paused or off as well, so the menu never names an app that is no longer in front.
    private(set) var lastForeignApp: (bundleID: String, name: String)?

    private let settings: CaptureSettings
    private let storeError: String?
    private var session: CaptureSession
    private let reader = ActivityReader()
    private var timer: Timer?
    private var asleep = false
    private var locked = false
    private var sessionInactive = false
    /// Keeps App Nap from stretching the sample timer while recording, idle, or timed-paused; a throttled timer would end
    /// segments early or a pause late.
    private var samplingActivity: NSObjectProtocol?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var onStateChange: (() -> Void)?

    init(settings: CaptureSettings, store: ActivityStore?, storeError: String?) {
        self.settings = settings
        self.storeError = storeError
        session = CaptureSession(storage: store, maxSampleInterval: Self.sampleInterval * 6)
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true; $0.tick() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.asleep = true; $0.tick() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false; $0.tick() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.asleep = false; $0.tick() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true; $0.tick() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; $0.tick() }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.foregroundChanged() }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true; $0.tick() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false; $0.tick() }
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Ends and saves the open segment and voids reads in flight, for example when a control changes. Controls call it
    /// before they change the settings: each change samples at once and may begin a read, which this would void.
    func endSegment() {
        let now = Date()
        mutate { $0.endSegment(at: now) }
    }

    /// Before quitting: ends the open segment and applies every queued write that storage accepts, not just one retry's
    /// worth, whether or not a segment was open. Whatever still fails stays reported by `hasUnsavedActivity` and
    /// `hasPendingDeletion`.
    func finishWrites() {
        let now = Date()
        mutate { $0.finish(at: now) }
    }

    /// Another app came to the front: what was in front ends now, and reads started before now are void.
    private func foregroundChanged() {
        let now = Date()
        mutate { $0.foregroundChanged(at: now) }
        tick()
    }

    func tick() {
        let now = Date()
        let front = NSWorkspace.shared.frontmostApplication
        if let front, let bundleID = front.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier, bundleID != "com.apple.loginwindow" {
            lastForeignApp = (bundleID, front.localizedName ?? bundleID)
        }
        let conditions = CaptureConditions(
            trackingOn: settings.onboardingCompleted && settings.trackingEnabled,
            paused: settings.pausedUntil.map { $0 > now } ?? false,
            asleep: asleep, locked: locked, sessionInactive: sessionInactive,
            secondsSinceInput: secondsSinceLastInput())
        mutate { $0.update(conditions, at: now) }
        guard state == .recording else { return }
        guard let app = front, let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier, bundleID != "com.apple.loginwindow" else {
            // pointInTime's own windows are not activity, and loginwindow in front means the lock screen or no app.
            mutate { $0.sample(nil, at: now) }
            return
        }
        let name = app.localizedName ?? bundleID
        let policy = settings.policy
        if policy.excludedBundleIDs.contains(bundleID) {
            // Excluded apps are never read: no title or URL request is made.
            mutate { $0.sample(policy.content(for: Activity(bundleID: bundleID, appName: name), at: now), at: now) }
            return
        }
        let pid = app.processIdentifier
        guard let ticket = session.beginRead(of: pid, at: now) else { return }
        reader.read(pid: pid, bundleID: bundleID, bundleURL: app.bundleURL, readTitle: AccessibilityAccess.isGranted) { result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.state == .recording, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      self.session.isCurrent(ticket) else {
                    // The foreground moved on while this read ran; read what is in front now instead of waiting a tick.
                    self.session.discard(ticket)
                    if self.state == .recording { self.tick() }
                    return
                }
                let activity = Activity(bundleID: bundleID, appName: name, windowTitle: result.title, url: result.url)
                let content = self.settings.policy.content(for: activity, at: now)
                self.mutate { $0.complete(ticket, with: content) }
            }
        }
    }

    /// Deletes today's or all captured activity after ending the open segment, so it cannot be written back. Returns
    /// the error when the deletion could not run yet; it stays queued and is retried on later ticks.
    func deleteActivity(all: Bool) -> String? {
        let now = Date()
        mutate { $0.delete(all: all, at: now, calendar: .current) }
        return session.writes.failure
    }

    /// Changes the session and reports a changed state or error to the menu.
    private func mutate(_ body: (inout CaptureSession) -> Void) {
        let before = (state, lastError)
        body(&session)
        updateSamplingActivity()
        if before != (state, lastError) { onStateChange?() }
    }

    /// Holds the App Nap opt-out while recording or idle, and through a timed pause so the timer that ends it is not
    /// throttled past its end date. Paused until resumed, off, asleep, or locked need no timely sample.
    private func updateSamplingActivity() {
        let timedPause = state == .paused && (settings.pausedUntil.map { $0 != .distantFuture } ?? false)
        if state == .recording || state == .idle || timedPause {
            if samplingActivity == nil {
                samplingActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                         reason: "Sampling the frontmost app")
            }
        } else if let activity = samplingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            samplingActivity = nil
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (CaptureController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }
}
