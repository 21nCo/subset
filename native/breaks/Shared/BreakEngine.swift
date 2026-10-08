import Combine
import Foundation
import UIKit

@MainActor
final class BreakEngine: ObservableObject {
    @Published var settings: BreakSettings {
        didSet {
            normalizeSettings()
            save()
            notifications.schedule(settings: settings, snapshot: snapshot, now: now)
            screenTime.refreshSchedules(settings: settings)
        }
    }
    @Published private(set) var snapshot: EngineSnapshot
    @Published private(set) var records: [BreakRecord]
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
        settings = loadedSettings
        snapshot = repository.loadSnapshot(settings: loadedSettings)
        records = repository.loadRecords()
        activeMessage = loadedSettings.customization.messages.first ?? "Take a slow breath."
        isBreakPresented = snapshot.phase == .breaking && (snapshot.breakEndsAt ?? .distantPast) > .now

        reconcileRestoredState()
    }

    deinit {
        timer?.invalidate()
    }

    var phase: BreakPhase { snapshot.phase }

    var nextBreakRemaining: TimeInterval {
        max(0, snapshot.nextBreakAt.timeIntervalSince(now))
    }

    var breakRemaining: TimeInterval {
        max(0, (snapshot.breakEndsAt ?? now).timeIntervalSince(now))
    }

    var focusElapsed: TimeInterval {
        switch snapshot.phase {
        case .paused:
            max(0, settings.workInterval - (snapshot.pausedRemaining ?? settings.workInterval))
        case .focusing, .headsUp, .breaking:
            max(0, min(settings.workInterval, now.timeIntervalSince(snapshot.focusStartedAt)))
        }
    }

    var breakProgress: Double {
        guard let started = snapshot.breakStartedAt, let end = snapshot.breakEndsAt, end > started else { return 0 }
        return min(1, max(0, now.timeIntervalSince(started) / end.timeIntervalSince(started)))
    }

    var snoozesRemaining: Int {
        max(0, settings.snoozesAllowedPerDay - snapshot.snoozesUsedToday)
    }

    var canSkipBreak: Bool {
        switch settings.discipline {
        case .casual: true
        case .balanced: now.timeIntervalSince(snapshot.breakStartedAt ?? now) >= 5
        case .hardcore: false
        }
    }

    var canEndEarly: Bool {
        settings.allowEarlyEnd && breakProgress >= settings.earlyEndProgress
    }

    var dashboardStats: DashboardStats {
        BreakMath.stats(records: records, snapshot: snapshot, now: now)
    }

    var nextPlannedBreak: (PlannedBreak, Date)? {
        BreakMath.nextPlannedBreak(settings: settings, after: now)
    }

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
            startBreak(kind: nextBreakKind())
        } else if command.hasPrefix("snooze:"), let minutes = Int(command.split(separator: ":").last ?? "") {
            snooze(minutes: minutes)
        } else if command == "pause" {
            pause()
        } else if command == "resume" {
            resume()
        } else if command == "focus:on", settings.smartPause.focusMode {
            pause()
        } else if command == "focus:off", snapshot.phase == .paused {
            resume()
        } else if command.hasPrefix("planned:"),
                  let id = UUID(uuidString: String(command.dropFirst("planned:".count))),
                  let planned = settings.plannedBreaks.first(where: { $0.id == id }),
                  planned.occurs(on: .now) {
            startBreak(kind: .planned, duration: planned.duration, plannedName: planned.name)
        }
    }

    func startBreak(kind: BreakKind = .manual, duration: TimeInterval? = nil, plannedName: String? = nil) {
        guard snapshot.phase != .breaking else { return }
        let startedAt = Date()
        let resolvedDuration = duration ?? durationForBreak(kind)
        let endsAt = startedAt.addingTimeInterval(resolvedDuration)

        now = startedAt
        snapshot.phase = .breaking
        snapshot.breakStartedAt = startedAt
        snapshot.breakEndsAt = endsAt
        snapshot.activeKind = kind
        snapshot.activePlannedBreakName = plannedName
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
        notifications.notifyBreakStarted(duration: resolvedDuration)
        SharedStore.defaults.set(endsAt, forKey: SharedStore.activeBreakEndKey)
        save()

        if settings.automation.runStartShortcut {
            shortcuts.run(named: settings.automation.startShortcutName)
        }
        Task {
            await liveActivity.start(kind: kind, startedAt: startedAt, endsAt: endsAt, message: activeMessage)
        }
    }

    func endBreak(completed: Bool = true) {
        guard snapshot.phase == .breaking else { return }
        let endedAt = Date()
        let startedAt = snapshot.breakStartedAt ?? endedAt
        let kind = snapshot.activeKind ?? .manual
        let plannedDuration = max(0, (snapshot.breakEndsAt ?? endedAt).timeIntervalSince(startedAt))

        records.append(BreakRecord(
            startedAt: startedAt,
            endedAt: endedAt,
            plannedDuration: plannedDuration,
            kind: kind,
            completed: completed,
            skipped: !completed
        ))
        if completed && kind == .short {
            snapshot.completedShortBreaks += 1
        }

        snapshot.phase = .focusing
        snapshot.focusStartedAt = endedAt
        snapshot.nextBreakAt = endedAt.addingTimeInterval(settings.workInterval)
        snapshot.breakStartedAt = nil
        snapshot.breakEndsAt = nil
        snapshot.activeKind = nil
        snapshot.activePlannedBreakName = nil
        snapshot.deliveredHeadsUpFor = nil
        isBreakPresented = false
        screenTime.clearShield()
        sounds.play(
            name: settings.customization.soundName,
            volume: settings.customization.soundVolume,
            customFilename: settings.customization.customSoundFilename,
            isCompletion: true
        )
        SharedStore.defaults.removeObject(forKey: SharedStore.activeBreakEndKey)
        notifications.schedule(settings: settings, snapshot: snapshot, now: endedAt)
        save()

        if settings.automation.runEndShortcut {
            shortcuts.run(named: settings.automation.endShortcutName)
        }
        Task { await liveActivity.end() }
    }

    @discardableResult
    func skipActiveBreak() -> Bool {
        guard canSkipBreak else { return false }
        endBreak(completed: false)
        return true
    }

    func snooze(minutes: Int) {
        guard snapshot.phase != .breaking, snoozesRemaining > 0 else { return }
        resetDailyCountersIfNeeded()
        snapshot.snoozesUsedToday += 1
        snapshot.phase = .focusing
        snapshot.nextBreakAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        snapshot.deliveredHeadsUpFor = nil
        isHeadsUpPresented = false
        save()
        notifications.schedule(settings: settings, snapshot: snapshot, now: now)
    }

    func skipUpcomingBreak() {
        guard settings.discipline != .hardcore else { return }
        let instant = Date()
        records.append(BreakRecord(
            startedAt: instant,
            endedAt: instant,
            plannedDuration: durationForBreak(nextBreakKind()),
            kind: nextBreakKind(),
            completed: false,
            skipped: true
        ))
        snapshot.phase = .focusing
        snapshot.focusStartedAt = instant
        snapshot.nextBreakAt = instant.addingTimeInterval(settings.workInterval)
        snapshot.deliveredHeadsUpFor = nil
        isHeadsUpPresented = false
        save()
        notifications.schedule(settings: settings, snapshot: snapshot, now: instant)
    }

    func pause() {
        guard snapshot.phase != .breaking, snapshot.phase != .paused else { return }
        snapshot.pausedRemaining = nextBreakRemaining
        snapshot.phase = .paused
        isHeadsUpPresented = false
        save()
        notifications.schedule(settings: settings, snapshot: snapshot, now: now)
    }

    func resume() {
        guard snapshot.phase == .paused else { return }
        let remaining = snapshot.pausedRemaining ?? settings.workInterval
        snapshot.phase = .focusing
        snapshot.focusStartedAt = Date().addingTimeInterval(-(settings.workInterval - remaining))
        snapshot.nextBreakAt = Date().addingTimeInterval(remaining)
        snapshot.pausedRemaining = nil
        save()
        notifications.schedule(settings: settings, snapshot: snapshot, now: now)
    }

    func resetToday() {
        let start = Calendar.current.startOfDay(for: Date())
        records.removeAll { $0.startedAt >= start }
        snapshot.snoozesUsedToday = 0
        snapshot.snoozeDay = start
        snapshot.completedShortBreaks = 0
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
        resetDailyCountersIfNeeded()
        processPendingCommand()

        if snapshot.phase == .breaking {
            if now >= snapshot.breakEndsAt ?? .distantFuture {
                endBreak(completed: true)
            }
            return
        }

        guard snapshot.phase != .paused else { return }
        guard settings.officeHours.contains(now) else {
            if snapshot.nextBreakAt <= now {
                snapshot.focusStartedAt = now
                snapshot.nextBreakAt = now.addingTimeInterval(settings.workInterval)
                save()
            }
            return
        }

        if let (planned, occurrence) = duePlannedBreak(at: now) {
            snapshot.deliveredPlannedOccurrences[planned.id.uuidString] = occurrence
            startBreak(kind: .planned, duration: planned.duration, plannedName: planned.name)
            return
        }

        let headsUpAt = snapshot.nextBreakAt.addingTimeInterval(-settings.reminder.headsUpLeadTime)
        if settings.reminder.headsUpEnabled,
           now >= headsUpAt,
           now < snapshot.nextBreakAt,
           snapshot.deliveredHeadsUpFor != snapshot.nextBreakAt {
            snapshot.phase = .headsUp
            snapshot.deliveredHeadsUpFor = snapshot.nextBreakAt
            isHeadsUpPresented = true
            save()
        }

        if now >= snapshot.nextBreakAt {
            startBreak(kind: nextBreakKind())
        }
    }

    private func nextBreakKind() -> BreakKind {
        guard settings.longBreakEnabled else { return .short }
        return (snapshot.completedShortBreaks + 1).isMultiple(of: max(1, settings.longBreakFrequency)) ? .long : .short
    }

    private func durationForBreak(_ kind: BreakKind) -> TimeInterval {
        switch kind {
        case .short: settings.shortBreakDuration
        case .long: settings.longBreakDuration
        case .planned: settings.plannedBreaks.first?.duration ?? settings.longBreakDuration
        case .manual: settings.shortBreakDuration
        }
    }

    private func duePlannedBreak(at date: Date) -> (PlannedBreak, Date)? {
        for planned in settings.plannedBreaks where planned.isEnabled {
            guard let occurrence = planned.occurrence(on: date) else { continue }
            let alreadyDelivered = snapshot.deliveredPlannedOccurrences[planned.id.uuidString]
            if date >= occurrence,
               date < occurrence.addingTimeInterval(60),
               alreadyDelivered.map({ !Calendar.current.isDate($0, inSameDayAs: occurrence) }) ?? true {
                return (planned, occurrence)
            }
        }
        return nil
    }

    private func resetDailyCountersIfNeeded() {
        let today = Calendar.current.startOfDay(for: now)
        guard snapshot.snoozeDay != today else { return }
        snapshot.snoozeDay = today
        snapshot.snoozesUsedToday = 0
        snapshot.deliveredPlannedOccurrences = [:]
        save()
    }

    private func reconcileRestoredState() {
        now = .now
        if snapshot.phase == .breaking {
            if let end = snapshot.breakEndsAt, end > now {
                isBreakPresented = true
                screenTime.applyShield(settings: settings)
            } else {
                snapshot.phase = .focusing
                snapshot.breakStartedAt = nil
                snapshot.breakEndsAt = nil
                snapshot.activeKind = nil
                snapshot.nextBreakAt = now.addingTimeInterval(settings.workInterval)
                isBreakPresented = false
                screenTime.clearShield()
            }
        } else if snapshot.nextBreakAt < now.addingTimeInterval(-settings.workInterval) {
            snapshot.focusStartedAt = now
            snapshot.nextBreakAt = now.addingTimeInterval(settings.workInterval)
        }
        save()
    }

    private func normalizeSettings() {
        settings.workInterval = max(60, settings.workInterval)
        settings.shortBreakDuration = max(5, settings.shortBreakDuration)
        settings.longBreakDuration = max(60, settings.longBreakDuration)
        settings.longBreakFrequency = max(1, settings.longBreakFrequency)
        settings.snoozesAllowedPerDay = max(0, settings.snoozesAllowedPerDay)
    }

    private func save() {
        repository.save(settings: settings, snapshot: snapshot, records: records)
    }
}
