import AppKit
import PointInTimeCore

/// Wires macOS signals to the segment recorder and the store. Samples every few seconds while tracking is allowed;
/// sleep, lock, fast user switching, idle, pause, and tracking off end the current segment.
@MainActor
final class CaptureController {
    static let sampleInterval: TimeInterval = 5
    static let idleThreshold: TimeInterval = 120
    static let flushInterval: TimeInterval = 60

    enum State: Equatable {
        case off, paused, idle, asleep, locked, inactiveSession, recording, storeUnavailable
    }

    private(set) var state: State = .off
    private(set) var lastError: String?
    /// The most recent foreground app other than pointInTime, offered by the menu's Exclude action. Kept current while
    /// paused or off as well, so the menu never names an app that is no longer in front.
    private(set) var lastForeignApp: (bundleID: String, name: String)?

    private let settings: CaptureSettings
    private let store: ActivityStore?
    private let reader = ActivityReader()
    private var sequencer = CaptureSequencer(recorder: SegmentRecorder(maxSampleInterval: CaptureController.sampleInterval * 6))
    private var timer: Timer?
    private var lastFlush = Date.distantPast
    private var asleep = false, locked = false, sessionInactive = false
    /// When recording last resumed after sleep, lock, pause, or tracking off. Idle retraction never reaches before it,
    /// so input-free time spent asleep or paused cannot delete what was recorded earlier.
    private var recordingSince = Date.distantPast
    /// Keeps App Nap from stretching the sample timer while recording, idle, or timed-paused; a throttled timer would end
    /// segments early or a pause late.
    private var samplingActivity: NSObjectProtocol?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var onStateChange: (() -> Void)?

    init(settings: CaptureSettings, store: ActivityStore?, storeError: String?) {
        self.settings = settings
        self.store = store
        self.lastError = storeError
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true; $0.endSegment() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.asleep = true; $0.endSegment() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false; $0.tick() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.asleep = false; $0.tick() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true; $0.endSegment() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; $0.tick() }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.foregroundChanged() }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true; $0.endSegment() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false; $0.tick() }
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Ends and saves the open segment, for example before quitting or when a control changes.
    func endSegment(at date: Date = Date()) {
        if let segment = sequencer.gap(at: date) { persist(segment) }
        refreshState()
    }

    /// Another app came to the front: what was in front ends now, and reads started before now are void.
    private func foregroundChanged() {
        apply(sequencer.foregroundChanged(at: Date()), at: Date())
        tick()
    }

    func tick() {
        let now = Date()
        let front = NSWorkspace.shared.frontmostApplication
        if let front, let bundleID = front.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier, bundleID != "com.apple.loginwindow" {
            lastForeignApp = (bundleID, front.localizedName ?? bundleID)
        }
        refreshState(now: now)
        guard state == .recording || state == .idle else {
            if sequencer.open != nil { endSegment(at: now) }
            return
        }
        let idle = secondsSinceLastInput()
        if idle >= Self.idleThreshold {
            if state != .idle { retractIdleTime(since: max(now.addingTimeInterval(-idle), recordingSince), until: now) }
            setState(.idle)
            return
        }
        setState(.recording)
        guard let app = front, let bundleID = app.bundleIdentifier else {
            apply(sequencer.sample(nil, at: now), at: now)
            return
        }
        if bundleID == Bundle.main.bundleIdentifier || bundleID == "com.apple.loginwindow" {
            // pointInTime's own windows are not activity, and loginwindow in front means the lock screen or no app.
            apply(sequencer.sample(nil, at: now), at: now)
            return
        }
        let name = app.localizedName ?? bundleID
        let policy = settings.policy
        if policy.excludedBundleIDs.contains(bundleID) {
            // Excluded apps are never read: no title or URL request is made.
            apply(sequencer.sample(policy.content(for: Activity(bundleID: bundleID, appName: name), at: now), at: now), at: now)
            return
        }
        let pid = app.processIdentifier
        guard let ticket = sequencer.beginRead(of: pid, at: now) else { return }
        reader.read(pid: pid, bundleID: bundleID, bundleURL: app.bundleURL, readTitle: AccessibilityAccess.isGranted) { result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.state == .recording, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      self.sequencer.isCurrent(ticket) else {
                    // The foreground moved on while this read ran; read what is in front now instead of waiting a tick.
                    self.sequencer.discard(ticket)
                    if self.state == .recording { self.tick() }
                    return
                }
                let activity = Activity(bundleID: bundleID, appName: name, windowTitle: result.title, url: result.url)
                self.apply(self.sequencer.complete(ticket, with: self.settings.policy.content(for: activity, at: now)), at: now)
            }
        }
    }

    /// Ends recording when idle began and removes anything stored after that: the flushed part of the open segment,
    /// and segments that closed while the user was away because a title or app changed without input. The WAL is then
    /// checkpointed, so the retracted titles and URLs do not linger in it.
    private func retractIdleTime(since idleStart: Date, until now: Date) {
        endSegment(at: idleStart)
        guard let store, now > idleStart else { return }
        do {
            try store.deleteData(from: idleStart, to: now)
            try store.checkpoint()
        } catch {
            lastError = String(describing: error)
            onStateChange?()
        }
    }

    /// Saves segments that closed and, at most once a minute, the open one.
    private func apply(_ closed: [Segment], at date: Date) {
        for segment in closed { persist(segment) }
        if let open = sequencer.open, date.timeIntervalSince(lastFlush) >= Self.flushInterval {
            persist(open)
            lastFlush = date
        }
    }

    private func persist(_ segment: Segment) {
        guard let store else { return }
        do {
            try store.save(segment)
            if lastError != nil { lastError = nil; onStateChange?() }
        } catch {
            lastError = String(describing: error)
            onStateChange?()
        }
    }

    private func refreshState(now: Date = Date()) {
        let next: State
        if store == nil { next = .storeUnavailable }
        else if !settings.onboardingCompleted || !settings.trackingEnabled { next = .off }
        else if settings.isPaused(at: now) { next = .paused }
        else if asleep { next = .asleep }
        else if locked { next = .locked }
        else if sessionInactive { next = .inactiveSession }
        else if state == .idle || state == .recording { next = state }
        else { next = .recording }
        setState(next, now: now)
    }

    private func setState(_ next: State, now: Date = Date()) {
        // A pause can change from timed to until-resumed without leaving `paused`, which changes the App Nap hold.
        guard next != state else { updateSamplingActivity(); return }
        if next == .recording, state != .idle { recordingSince = now }
        state = next
        updateSamplingActivity()
        onStateChange?()
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
