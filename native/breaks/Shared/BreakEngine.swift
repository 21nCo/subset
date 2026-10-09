import Combine
import Foundation

@MainActor
final class BreakEngine: ObservableObject {
    /// The shared schedule (`BreakScheduler`) is the source of truth; this class performs its iOS effects.
    @Published private var core: BreakScheduler
    @Published private(set) var now = Date()
    @Published var isBreakPresented = false
    @Published var isHeadsUpPresented = false
    @Published private(set) var activeMessage: String
    @Published var setupError: String?

    let notifications: NotificationCoordinator
    let screenTime: ScreenTimeCoordinator

    private let repository: BreakRepository
    private let liveActivity = BreakActivityCoordinator()
    private let shortcuts = ShortcutAutomationCoordinator()
    private let sounds = BreakSoundCoordinator()
    private var timer: Timer?

    init(
        repository: BreakRepository = BreakRepository(),
        notifications: NotificationCoordinator? = nil,
        screenTime: ScreenTimeCoordinator? = nil
    ) {
        self.repository = repository
        self.notifications = notifications ?? NotificationCoordinator()
        self.screenTime = screenTime ?? ScreenTimeCoordinator()

        let loadedSettings = repository.loadSettings()
        core = BreakScheduler(
            settings: loadedSettings,
            snapshot: repository.loadSnapshot(settings: loadedSettings),
            records: repository.loadRecords()
        )
        activeMessage = loadedSettings.customization.messages.first ?? "Take a slow breath."

        reconcileRestoredState()
    }

    deinit {
        timer?.invalidate()
    }

    var settings: BreakSettings {
        get { core.settings }
        set {
            core.settings = newValue
            core.normalizeSettings()
            save()
            notifications.schedule(settings: core.settings, snapshot: snapshot, now: now)
            screenTime.refreshSchedules(settings: core.settings)
        }
    }

    var snapshot: EngineSnapshot { core.snapshot }
    var records: [BreakRecord] { core.records }
    var phase: BreakPhase { core.phase }
    var nextBreakRemaining: TimeInterval { core.nextBreakRemaining(now: now) }
    var breakRemaining: TimeInterval { core.breakRemaining(now: now) }
    var focusElapsed: TimeInterval { core.focusElapsed(now: now) }
    var breakProgress: Double { core.breakProgress(now: now) }
    var snoozesRemaining: Int { core.snoozesRemaining }
    var canSkipBreak: Bool { core.canSkipBreak(now: now) }
    var canEndEarly: Bool { core.canEndEarly(now: now) }
    var upcomingBreakKind: BreakKind { core.upcomingBreakKind }
    var dashboardStats: DashboardStats { core.stats(now: now) }
    var nextPlannedBreak: (PlannedBreak, Date)? { core.nextPlannedBreak(after: now) }

    func start() {
        guard timer == nil else { return }
        now = .now
        processPendingCommand()
        notifications.refreshAuthorizationStatus()
        screenTime.refreshAuthorizationStatus()
        screenTime.refreshSchedules(settings: settings)
        notifications.schedule(settings: settings, snapshot: snapshot, now: now)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func requestSetupPermissions() async {
        await notifications.requestAuthorization()
        await screenTime.requestAuthorization()
        screenTime.refreshSchedules(settings: settings)
        if let error = screenTime.lastError {
            setupError = error
        }
    }

    func processPendingCommand() {
        guard let command = repository.takeCommand() else { return }
        if command == "start" || command == "open" {
            startBreak(kind: core.upcomingBreakKind)
        } else if command.hasPrefix("snooze:"), let minutes = Int(command.split(separator: ":").last ?? "") {
            snooze(minutes: minutes)
        } else if command == "pause" {
            pause()
        } else if command == "resume" {
            resume()
        } else if command == "focus:on", settings.smartPause.focusMode {
            perform { $0.pause(reason: .focus, now: $1) }
        } else if command == "focus:off", snapshot.phase == .paused, snapshot.pauseReason != .manual {
            resume()
        } else if command.hasPrefix("planned:"),
                  let id = UUID(uuidString: String(command.dropFirst("planned:".count))),
                  let planned = settings.plannedBreaks.first(where: { $0.id == id }),
                  planned.occurs(on: .now) {
            startBreak(kind: .planned, duration: planned.duration, plannedName: planned.name)
        }
    }

    func startBreak(kind: BreakKind = .manual, duration: TimeInterval? = nil, plannedName: String? = nil) {
        perform { $0.startBreak(kind: kind, duration: duration, plannedName: plannedName, now: $1) }
    }

    func endBreak(completed: Bool = true) {
        perform { $0.endBreak(completed: completed, now: $1) }
    }

    @discardableResult
    func skipActiveBreak() -> Bool {
        let events = perform { $0.skipActiveBreak(now: $1) }
        return !events.isEmpty
    }

    func snooze(minutes: Int) {
        perform { $0.snooze(minutes: minutes, now: $1) }
    }

    func skipUpcomingBreak() {
        perform { $0.skipUpcomingBreak(now: $1) }
    }

    func pause() {
        perform { $0.pause(now: $1) }
    }

    func resume() {
        perform { $0.resume(now: $1) }
    }

    func resetToday() {
        core.resetToday(now: .now)
        save()
    }

    func previewSound() {
        sounds.play(
            name: settings.customization.soundName,
            volume: settings.customization.soundVolume,
            customFilename: settings.customization.customSoundFilename,
            isCompletion: false
        )
    }

    private func tick() {
        now = .now
        processPendingCommand()
        let before = core.snapshot
        let events = core.tick(now: now)
        handle(events)
        if core.snapshot != before { save() }
    }

    @discardableResult
    private func perform(_ operation: (inout BreakScheduler, Date) -> [BreakScheduler.Event]) -> [BreakScheduler.Event] {
        now = .now
        let events = operation(&core, now)
        guard !events.isEmpty else { return events }
        handle(events)
        save()
        return events
    }

    private func handle(_ events: [BreakScheduler.Event]) {
        for event in events {
            switch event {
            case .breakStarted(let kind, let duration):
                didStartBreak(kind: kind, duration: duration)
            case .breakEnded(let completed):
                didEndBreak(completed: completed)
            case .breakSnoozed(_, let duringBreak):
                isHeadsUpPresented = false
                if duringBreak { didLeaveBreak() }
                notifications.schedule(settings: settings, snapshot: snapshot, now: now)
            case .upcomingBreakSkipped:
                isHeadsUpPresented = false
                notifications.schedule(settings: settings, snapshot: snapshot, now: now)
            case .headsUp:
                isHeadsUpPresented = true
            case .paused, .resumed:
                isHeadsUpPresented = false
                notifications.schedule(settings: settings, snapshot: snapshot, now: now)
            case .focusReset, .wellness:
                // iOS delivers posture and blink reminders as scheduled notifications.
                break
            }
        }
    }

    private func didStartBreak(kind: BreakKind, duration: TimeInterval) {
        let startedAt = snapshot.breakStartedAt ?? now
        let endsAt = snapshot.breakEndsAt ?? now.addingTimeInterval(duration)
        isHeadsUpPresented = false
        isBreakPresented = true
        activeMessage = settings.customization.messages.randomElement() ?? "Let your eyes rest."
        screenTime.applyShield(settings: settings)
        sounds.play(
            name: settings.customization.soundName,
            volume: settings.customization.soundVolume,
            customFilename: settings.customization.customSoundFilename,
            isCompletion: false
        )
        notifications.notifyBreakStarted(duration: duration)
        SharedStore.defaults.set(endsAt, forKey: SharedStore.activeBreakEndKey)

        if settings.automation.runStartShortcut {
            shortcuts.run(named: settings.automation.startShortcutName)
        }
        let message = activeMessage
        Task {
            await liveActivity.start(kind: kind, startedAt: startedAt, endsAt: endsAt, message: message)
        }
    }

    private func didEndBreak(completed: Bool) {
        isHeadsUpPresented = false
        didLeaveBreak()
        sounds.play(
            name: settings.customization.soundName,
            volume: settings.customization.soundVolume,
            customFilename: settings.customization.customSoundFilename,
            isCompletion: true
        )
        notifications.schedule(settings: settings, snapshot: snapshot, now: now)

        if settings.automation.runEndShortcut {
            shortcuts.run(named: settings.automation.endShortcutName)
        }
    }

    private func didLeaveBreak() {
        isBreakPresented = false
        screenTime.clearShield()
        SharedStore.defaults.removeObject(forKey: SharedStore.activeBreakEndKey)
        Task { await liveActivity.end() }
    }

    private func reconcileRestoredState() {
        now = .now
        if core.reconcileRestoredState(now: now) {
            isBreakPresented = true
            screenTime.applyShield(settings: settings)
        } else {
            isBreakPresented = false
            screenTime.clearShield()
        }
        save()
    }

    private func save() {
        repository.save(settings: core.settings, snapshot: core.snapshot, records: core.records)
    }
}
