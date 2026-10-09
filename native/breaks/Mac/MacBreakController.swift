import AppKit
import Combine
import ServiceManagement

/// Runs the shared `BreakScheduler` on macOS and performs its effects: the menu bar status, the heads-up
/// notice, the full-screen overlay on every display, blink and posture nudges, and sounds.
@MainActor
final class MacBreakController: ObservableObject {
    @Published private var core: BreakScheduler
    @Published private(set) var now = Date()
    @Published private(set) var lastReading = ActivitySignals.Reading(idleSeconds: 0, signals: [], frontmostAppName: nil)
    @Published private(set) var activeMessage: String
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var launchAtLoginError: String?

    private let repository: BreakRepository
    private let signals = ActivitySignals()
    private let sounds = BreakSoundCoordinator()
    private lazy var overlay = BreakOverlayController(controller: self)
    private lazy var notice = HeadsUpPanelController(controller: self)
    private lazy var nudges = WellnessNudgeController()
    private var timer: Timer?
    private var lastSignalReadAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init(repository: BreakRepository = BreakRepository()) {
        self.repository = repository
        let settings = repository.loadSettings()
        core = BreakScheduler(
            settings: settings,
            snapshot: repository.loadSnapshot(settings: settings),
            records: repository.loadRecords()
        )
        activeMessage = settings.customization.messages.first ?? "Let your eyes rest."
    }

    // MARK: - State for views

    var settings: BreakSettings {
        get { core.settings }
        set {
            core.settings = newValue
            core.normalizeSettings()
            lastSignalReadAt = .distantPast
            save()
        }
    }

    var snapshot: EngineSnapshot { core.snapshot }
    var records: [BreakRecord] { core.records }
    var phase: BreakPhase { core.phase }
    var pauseReason: PauseReason? { core.snapshot.pauseReason }
    var nextBreakRemaining: TimeInterval { core.nextBreakRemaining(now: now) }
    var breakRemaining: TimeInterval { core.breakRemaining(now: now) }
    var breakProgress: Double { core.breakProgress(now: now) }
    var snoozesRemaining: Int { core.snoozesRemaining }
    var canSkipBreak: Bool { core.canSkipBreak(now: now) }
    var skipAvailableIn: TimeInterval? { core.skipAvailableIn(now: now) }
    var canSnoozeActiveBreak: Bool { core.canSnoozeActiveBreak(now: now) }
    var canSkipUpcomingBreak: Bool { core.canSkipUpcomingBreak }
    var canEndEarly: Bool { core.canEndEarly(now: now) }
    var upcomingBreakKind: BreakKind { core.upcomingBreakKind }
    var stats: DashboardStats { core.stats(now: now) }
    var nextPlannedBreak: (PlannedBreak, Date)? { core.nextPlannedBreak(after: now) }
    var isWithinOfficeHours: Bool { settings.officeHours.contains(now) }

    var activeBreakTitle: String {
        snapshot.activePlannedBreakName ?? snapshot.activeKind?.title ?? BreakKind.manual.title
    }

    /// Short text for the menu bar.
    var menuBarText: String {
        switch phase {
        case .breaking: breakRemaining.clockDuration
        case .paused: "Paused"
        case .focusing, .headsUp:
            isWithinOfficeHours ? nextBreakRemaining.clockDuration : "Off hours"
        }
    }

    var menuBarSymbol: String {
        switch phase {
        case .breaking: "cup.and.saucer.fill"
        case .paused: "pause.circle"
        case .headsUp: "eye.fill"
        case .focusing: "eye"
        }
    }

    var statusLine: String {
        switch phase {
        case .breaking: "\(activeBreakTitle), \(breakRemaining.spokenDuration) left"
        case .paused:
            if let until = snapshot.pausedUntil {
                "Paused until \(until.formatted(date: .omitted, time: .shortened))"
            } else {
                pauseReason?.title ?? "Paused"
            }
        case .focusing, .headsUp:
            isWithinOfficeHours
                ? "\(upcomingBreakKind.title) in \(nextBreakRemaining.spokenDuration)"
                : "Outside office hours"
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        now = .now
        core.reconcileRestoredState(now: now)
        save()
        if phase == .breaking { overlay.show() }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.2
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.overlay.screensChanged() }
        })
        refreshLaunchAtLogin()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        save()
    }

    // MARK: - Operations

    func startBreak() { perform { $0.startBreak(kind: .manual, now: $1) } }
    func startUpcomingBreak() { perform { s, now in s.startBreak(kind: s.upcomingBreakKind, now: now) } }
    func endBreak() { perform { $0.endBreak(completed: true, now: $1) } }
    func skipActiveBreak() { perform { $0.skipActiveBreak(now: $1) } }
    func skipUpcomingBreak() { perform { $0.skipUpcomingBreak(now: $1) } }
    func snooze(minutes: Int) { perform { $0.snooze(minutes: minutes, now: $1) } }
    func pause(for duration: TimeInterval? = nil) {
        perform { s, now in s.pause(reason: .manual, until: duration.map { now.addingTimeInterval($0) }, now: now) }
    }
    func resume() { perform { $0.resume(now: $1) } }
    func dismissHeadsUp() { notice.hide() }

    func resetToday() {
        core.resetToday(now: .now)
        save()
    }

    func previewSound() {
        playSound(completion: false)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    // MARK: - Tick and effects

    private func tick() {
        now = .now
        // Idle time is cheap and read every tick; device and power-assertion signals every few seconds.
        var reading = lastReading
        if now.timeIntervalSince(lastSignalReadAt) >= 3 {
            reading = signals.read(settings: core.settings)
            lastSignalReadAt = now
        } else {
            reading.idleSeconds = core.settings.desktop.idle.isEnabled ? ActivitySignals.idleSeconds() : 0
        }
        if reading != lastReading { lastReading = reading }
        let before = core.snapshot
        let events = core.tick(now: now, inputs: .init(idleSeconds: reading.idleSeconds, signals: reading.signals))
        handle(events)
        if core.snapshot != before { save() }
    }

    private func perform(_ operation: (inout BreakScheduler, Date) -> [BreakScheduler.Event]) {
        now = .now
        let events = operation(&core, now)
        guard !events.isEmpty else { return }
        handle(events)
        save()
    }

    private func handle(_ events: [BreakScheduler.Event]) {
        for event in events {
            switch event {
            case .headsUp:
                if settings.reminder.headsUpEnabled { notice.show() }
            case .breakStarted:
                notice.hide()
                activeMessage = settings.customization.messages.randomElement() ?? "Let your eyes rest."
                overlay.show()
                playSound(completion: false)
            case .breakEnded(let completed):
                overlay.hide()
                if completed { playSound(completion: true) }
            case .breakSnoozed(_, let duringBreak):
                notice.hide()
                if duringBreak { overlay.hide() }
            case .upcomingBreakSkipped, .paused:
                notice.hide()
            case .resumed, .focusReset:
                break
            case .wellness(let reminder):
                nudges.show(reminder, large: settings.wellness.largePresentation)
            }
        }
    }

    private func playSound(completion: Bool) {
        sounds.play(
            name: settings.customization.soundName,
            volume: settings.customization.soundVolume,
            customFilename: nil,
            isCompletion: completion
        )
    }

    private func save() {
        repository.save(settings: core.settings, snapshot: core.snapshot, records: core.records)
    }
}
