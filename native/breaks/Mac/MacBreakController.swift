import AppKit
import Combine
import ServiceManagement

/// Runs the shared `BreakScheduler` on macOS and performs its effects: the menu bar status, the heads-up
/// notice, the full-screen overlay on every display, blink and posture nudges, and sounds. Hard stops use the
/// same notice and overlay, with content from `HardStopPresentation`.
@MainActor
final class MacBreakController: ObservableObject {
    @Published private var core: BreakScheduler
    @Published private(set) var now = Date()
    @Published private(set) var lastReading = ActivitySignals.Reading(idleSeconds: 0, signals: [], frontmostAppName: nil)
    @Published private(set) var activeMessage: String
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var launchAtLoginError: String?
    /// The hard-stop notices waiting for the panel; the first is shown. Empty when the panel is closed or shows the
    /// regular heads-up.
    @Published private(set) var hardStopNotices = HardStopNoticeQueue()
    /// True while the meeting signal (microphone or camera in use) is on, read even when it does not pause reminders.
    @Published private(set) var inCall = false

    private let repository: BreakRepository
    private let signals = ActivitySignals()
    private let sounds = BreakSoundCoordinator()
    private lazy var overlay = BreakOverlayController(controller: self)
    private lazy var notice = HeadsUpPanelController(controller: self)
    private lazy var nudges = WellnessNudgeController()
    private var timer: Timer?
    private var lastSignalReadAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var sleptAt: Date?
    /// The meeting signal from the last signal read, including one read only for hard stops.
    private var callReading = false
    /// The extension whose ending notice was already shown.
    private var warnedExtensionUntil: Date?
    /// True during the first tick after launch, which reports what happened to a restored hard stop while the app was off.
    private var isRestoring = false

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
            if !core.settings.reminder.headsUpEnabled { hideRegularHeadsUp() }
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

    /// Why the hard-stop notice is open.
    var hardStopNoticeSubject: HardStopPresentation.NoticeSubject? { hardStopNotices.shown }

    var hardStop: HardStopPresentation {
        HardStopPresentation(scheduler: core, noticeSubject: hardStopNoticeSubject, inCall: inCall, now: now)
    }

    var activeBreakTitle: String {
        snapshot.activePlannedBreakName ?? snapshot.activeKind?.title ?? BreakKind.manual.title
    }

    /// Short text for the menu bar.
    var menuBarText: String {
        if let hardStop = hardStop.menuBar { return hardStop.text }
        return switch phase {
        case .breaking: breakRemaining.clockDuration
        case .paused: "Paused"
        case .focusing, .headsUp:
            isWithinOfficeHours ? nextBreakRemaining.clockDuration : "Off hours"
        }
    }

    var menuBarSymbol: String {
        if let hardStop = hardStop.menuBar { return hardStop.symbol }
        return switch phase {
        case .breaking: "cup.and.saucer.fill"
        case .paused: "pause.circle"
        case .headsUp: "eye.fill"
        case .focusing: "eye"
        }
    }

    var statusLine: String {
        if let hardStop = hardStop.menuBar { return hardStop.statusLine }
        return switch phase {
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
        // A restored hard stop is shown by the tick below, after the scheduler has ended, resumed, or kept it.
        if phase == .breaking, snapshot.activeKind != .hardStop { overlay.show() }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.2
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleptAt = .now }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.didWake() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.overlay.screensChanged() }
        })
        refreshLaunchAtLogin()
        // Tick once now, so a restored hard stop covers the screens without waiting for the timer.
        isRestoring = true
        tick()
        isRestoring = false
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

    /// Runs a confirmed Extend or Dismiss, if the overlay still offers it for the same stop.
    func performHardStopAction(_ target: HardStopConfirmation.Target) {
        perform { HardStopPresentation.perform(target, on: &$0, now: $1) }
    }

    /// **Start now** on the hard-stop notice: starts the warned stop, or ends the extension that is running out.
    func startHardStopNow() {
        switch hardStopNoticeSubject {
        case .warning(let id, _): perform { $0.startHardStopEarly(id: id, now: $1) }
        case .extensionEnding: perform { $0.endHardStopExtension(now: $1) }
        case nil: break
        }
    }

    /// Closes the shown hard-stop notice; the next one waiting, if any, takes its place.
    func closeHardStopNotice() {
        guard hardStopNoticeSubject != nil else { return }
        hardStopNotices.closeShown()
        syncHardStopNotice(bringToFront: true)
    }

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

    /// Time asleep is time away. The input that wakes the Mac resets the idle reading, so pass the sleep
    /// gap through the idle path: a long sleep then starts a fresh interval instead of a break.
    private func didWake() {
        let gap = sleptAt.map { Date.now.timeIntervalSince($0) } ?? 0
        sleptAt = nil
        tick(awayAtLeast: gap)
    }

    private func tick(awayAtLeast away: TimeInterval = 0) {
        now = .now
        // Idle time is cheap and read every tick; device and power-assertion signals every few seconds.
        var reading = lastReading
        let readsSignals = now.timeIntervalSince(lastSignalReadAt) >= 3
        if readsSignals {
            reading = signals.read(settings: core.settings)
            lastSignalReadAt = now
        } else {
            reading.idleSeconds = core.settings.desktop.idle.isEnabled ? ActivitySignals.idleSeconds() : 0
        }
        if reading != lastReading { lastReading = reading }
        // Hard stops wait for calls even when the meeting smart pause is off; the scheduler ignores the signal
        // for pausing then.
        var signals = reading.signals
        if readsSignals {
            callReading = signals.contains(.meeting)
                || (waitsForCalls && !core.settings.smartPause.meetingsAndCalls
                    && (ActivitySignals.isMicrophoneInUse() || ActivitySignals.isCameraInUse()))
        }
        if callReading { signals.insert(.meeting) }
        if inCall != callReading { inCall = callReading }
        let idle = core.settings.desktop.idle.isEnabled ? max(reading.idleSeconds, away) : reading.idleSeconds
        let before = core.snapshot
        let events = core.tick(now: now, inputs: .init(idleSeconds: idle, signals: signals))
        handle(events)
        if core.snapshot != before { save() }
    }

    private var waitsForCalls: Bool {
        core.settings.hardStops.contains { $0.isEnabled && $0.duringCalls == .waitForCallToEnd }
            || !core.snapshot.hardStopsWaitingForCall.isEmpty
    }

    private func perform(_ operation: (inout BreakScheduler, Date) -> [BreakScheduler.Event]) {
        now = .now
        let events = operation(&core, now)
        guard !events.isEmpty else { return }
        handle(events)
        save()
    }

    private func handle(_ events: [BreakScheduler.Event]) {
        // When a hard stop starts in the same batch as a break or another stop ends, the overlay stays up and
        // changes content instead of fading out and back in, and only the start chime plays.
        let startsHardStop = events.contains { if case .hardStopStarted = $0 { true } else { false } }
        for event in events {
            switch event {
            case .headsUp:
                // Held back while a hard-stop notice is open; it comes back when that notice closes.
                if settings.reminder.headsUpEnabled, hardStopNoticeSubject == nil { notice.show(kind: .regular) }
            case .headsUpCancelled:
                hideRegularHeadsUp()
            case .breakStarted:
                hideRegularHeadsUp()
                activeMessage = settings.customization.messages.randomElement() ?? "Let your eyes rest."
                overlay.show()
                playSound(completion: false)
            case .breakEnded(let completed):
                guard !startsHardStop else { break }
                overlay.hide()
                if completed { playSound(completion: true) }
            case .breakSnoozed(_, let duringBreak):
                hideRegularHeadsUp()
                if duringBreak { overlay.hide() }
            case .upcomingBreakSkipped, .paused:
                hideRegularHeadsUp()
            case .resumed, .focusReset:
                break
            case .wellness(let reminder):
                nudges.show(reminder, large: settings.wellness.largePresentation)
            case .hardStopWarning(let id, let startsAt, _):
                showHardStopWarning(id: id, startsAt: startsAt)
            case .hardStopStarted:
                // Its warning is pruned below; one for a later stop stays.
                overlay.show()
                playSound(completion: false)
            case .hardStopExtended:
                overlay.hide()
                warnedExtensionUntil = nil
            case .hardStopResumed:
                overlay.show()
            case .hardStopEnded(_, let reason):
                // A missed stop never showed; another stop or a break may be on screen.
                guard reason != .missed, !startsHardStop else { break }
                overlay.hide()
                if HardStopPresentation.chimesOnEnd(reason, afterRelaunch: isRestoring) { playSound(completion: true) }
            }
        }
        reconcileHardStop()
    }

    /// Keeps the screen in line with the running hard stop: the overlay comes back after a relaunch or wake, notices
    /// close once they no longer apply (their stop started, was missed, or was removed, or the extension ended), and
    /// the notice before an extension runs out appears once.
    private func reconcileHardStop() {
        if hardStop.overlay != nil, !overlay.isVisible { overlay.show() }
        if let until = HardStopPresentation.extensionWarningDue(core, now: now), warnedExtensionUntil != until {
            warnedExtensionUntil = until
            hardStopNotices.add(.extensionEnding)
            syncHardStopNotice(bringToFront: true)
        } else {
            syncHardStopNotice()
        }
    }

    /// Queues a hard-stop warning. Hard-stop warnings ignore the heads-up switch, since each stop sets its own. The
    /// panel shows the notice before an extension runs out first, then the warning for the stop that starts first;
    /// the others wait.
    private func showHardStopWarning(id: UUID, startsAt: Date) {
        hardStopNotices.add(.warning(id: id, startsAt: startsAt))
        syncHardStopNotice(bringToFront: true)
    }

    /// Shows the first hard-stop notice that still applies, above the overlay while the overlay is up, or, once none
    /// is left, closes the panel and brings back a regular heads-up that it held back.
    private func syncHardStopNotice(bringToFront: Bool = false) {
        hardStopNotices.prune(scheduler: core, inCall: inCall, now: now)
        if hardStopNotices.shown != nil {
            let layer = HardStopPresentation.noticeLayer(showsHardStopNotice: true, overlayVisible: overlay.isVisible)
            if bringToFront || notice.kind != .hardStop {
                notice.show(kind: .hardStop, layer: layer)
            } else {
                notice.set(layer)
            }
        } else if notice.kind == .hardStop {
            notice.hide()
            if phase == .headsUp, settings.reminder.headsUpEnabled { notice.show(kind: .regular) }
        }
    }

    /// Hides the notice unless it shows a hard-stop notice, which regular break events do not withdraw.
    private func hideRegularHeadsUp() {
        if notice.kind != .hardStop { notice.hide() }
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
