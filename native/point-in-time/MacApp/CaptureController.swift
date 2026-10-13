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
    /// The most recent foreground app other than pointInTime, offered by the menu's Exclude action.
    private(set) var lastForeignApp: (bundleID: String, name: String)?

    private let settings: CaptureSettings
    private let store: ActivityStore?
    private let reader = ActivityReader()
    private var recorder = SegmentRecorder(maxSampleInterval: CaptureController.sampleInterval * 6)
    private var timer: Timer?
    private var lastFlush = Date.distantPast
    private var asleep = false, locked = false, sessionInactive = false
    /// Increments on every gap so a read that started before it cannot record afterwards.
    private var generation = 0
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
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.tick() }
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
        generation += 1
        if let segment = recorder.gap(at: date) { persist(segment) }
        refreshState()
    }

    func tick() {
        let now = Date()
        refreshState(now: now)
        guard state == .recording || state == .idle else {
            if recorder.open != nil { endSegment(at: now) }
            return
        }
        let idle = secondsSinceLastInput()
        if idle >= Self.idleThreshold {
            if state != .idle { retractIdleTime(since: now.addingTimeInterval(-idle), until: now) }
            setState(.idle)
            return
        }
        setState(.recording)
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else {
            apply(nil, at: now)
            return
        }
        if bundleID == Bundle.main.bundleIdentifier || bundleID == "com.apple.loginwindow" {
            // pointInTime's own windows are not activity, and loginwindow in front means the lock screen or no app.
            apply(nil, at: now)
            return
        }
        let name = app.localizedName ?? bundleID
        lastForeignApp = (bundleID, name)
        let policy = settings.policy
        if policy.excludedBundleIDs.contains(bundleID) {
            // Excluded apps are never read: no title or URL request is made.
            apply(policy.content(for: Activity(bundleID: bundleID, appName: name), at: now), at: now)
            return
        }
        let pid = app.processIdentifier
        let expectedGeneration = generation
        reader.read(pid: pid, bundleID: bundleID, readTitle: AccessibilityAccess.isGranted) { result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration, self.state == .recording,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                let activity = Activity(bundleID: bundleID, appName: name, windowTitle: result.title, url: result.url)
                self.apply(self.settings.policy.content(for: activity, at: now), at: now)
            }
        }
    }

    /// Ends recording when idle began and removes anything stored after that: the flushed part of the open segment,
    /// and segments that closed while the user was away because a title or app changed without input.
    private func retractIdleTime(since idleStart: Date, until now: Date) {
        endSegment(at: idleStart)
        guard let store, now > idleStart else { return }
        do {
            try store.deleteData(from: idleStart, to: now)
        } catch {
            lastError = String(describing: error)
            onStateChange?()
        }
    }

    private func apply(_ content: Segment?, at date: Date) {
        for segment in recorder.record(content, at: date) { persist(segment) }
        if let open = recorder.open, date.timeIntervalSince(lastFlush) >= Self.flushInterval {
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
        setState(next)
    }

    private func setState(_ next: State) {
        guard next != state else { return }
        state = next
        onStateChange?()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (CaptureController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }
}
