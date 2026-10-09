import Foundation

/// The platform-independent break schedule: focus intervals, heads-up, breaks, snoozes, pauses,
/// smart pause, idle handling, and blink and posture cadence.
///
/// It is a value type with no timers, UI, or system APIs. A platform host (the iOS `BreakEngine` or the
/// macOS `MacBreakController`) calls `tick(now:inputs:)` about once a second, feeds in the activity signals
/// its platform can observe, and performs the returned events (show an overlay, apply a shield, play a sound).
struct BreakScheduler: Sendable {
    enum Event: Equatable, Sendable {
        case headsUp(breakAt: Date)
        case breakStarted(BreakKind, duration: TimeInterval)
        case breakEnded(completed: Bool)
        case breakSnoozed(minutes: Int, duringBreak: Bool)
        case upcomingBreakSkipped
        case paused(PauseReason)
        case resumed(PauseReason)
        /// The user was away long enough that the absence counts as rest; the next interval starts fresh.
        case focusReset
        case wellness(WellnessReminder)
    }

    enum WellnessReminder: String, Equatable, Sendable {
        case blink
        case posture
    }

    /// Activity signals observed by the host for one tick.
    struct Inputs: Equatable, Sendable {
        /// Seconds since the last keyboard, mouse, or trackpad event. Hosts that cannot observe this pass 0.
        var idleSeconds: TimeInterval = 0
        /// Live smart-pause signals (`meeting`, `media`, `app`, `game`). Disabled ones are ignored.
        var signals: Set<PauseReason> = []
    }

    /// In Balanced mode, a break can be skipped or snoozed after this many seconds.
    static let balancedSkipDelay: TimeInterval = 5

    var settings: BreakSettings
    private(set) var snapshot: EngineSnapshot
    private(set) var records: [BreakRecord]
    var calendar: Calendar

    /// Transient (not persisted): when an enabled smart-pause signal was last observed.
    private(set) var lastSignalAt: Date?
    private(set) var lastBlinkAt: Date?
    private(set) var lastPostureAt: Date?

    init(settings: BreakSettings, snapshot: EngineSnapshot, records: [BreakRecord], calendar: Calendar = .current) {
        self.settings = settings
        self.snapshot = snapshot
        self.records = records
        self.calendar = calendar
        normalizeSettings()
    }

    // MARK: - Derived state

    var phase: BreakPhase { snapshot.phase }

    func nextBreakRemaining(now: Date) -> TimeInterval {
        if snapshot.phase == .paused {
            return snapshot.pausedRemaining ?? settings.workInterval
        }
        return max(0, snapshot.nextBreakAt.timeIntervalSince(now))
    }

    func breakRemaining(now: Date) -> TimeInterval {
        max(0, (snapshot.breakEndsAt ?? now).timeIntervalSince(now))
    }

    func focusElapsed(now: Date) -> TimeInterval {
        switch snapshot.phase {
        case .paused:
            max(0, settings.workInterval - (snapshot.pausedRemaining ?? settings.workInterval))
        case .focusing, .headsUp, .breaking:
            max(0, min(settings.workInterval, now.timeIntervalSince(snapshot.focusStartedAt)))
        }
    }

    func breakProgress(now: Date) -> Double {
        guard let started = snapshot.breakStartedAt, let end = snapshot.breakEndsAt, end > started else { return 0 }
        return min(1, max(0, now.timeIntervalSince(started) / end.timeIntervalSince(started)))
    }

    var snoozesRemaining: Int {
        max(0, settings.snoozesAllowedPerDay - snapshot.snoozesUsedToday)
    }

    func canSkipBreak(now: Date) -> Bool {
        switch settings.discipline {
        case .casual: true
        case .balanced: now.timeIntervalSince(snapshot.breakStartedAt ?? now) >= Self.balancedSkipDelay
        case .hardcore: false
        }
    }

    /// Seconds until a Balanced break can be skipped, or nil when no wait applies.
    func skipAvailableIn(now: Date) -> TimeInterval? {
        guard settings.discipline == .balanced, snapshot.phase == .breaking, !canSkipBreak(now: now) else { return nil }
        return Self.balancedSkipDelay - now.timeIntervalSince(snapshot.breakStartedAt ?? now)
    }

    func canEndEarly(now: Date) -> Bool {
        settings.allowEarlyEnd && breakProgress(now: now) >= settings.earlyEndProgress
    }

    var canSkipUpcomingBreak: Bool { settings.discipline != .hardcore }

    /// A break may be snoozed while it runs only when it could also be skipped, and a snooze is left.
    func canSnoozeActiveBreak(now: Date) -> Bool {
        snapshot.phase == .breaking && canSkipBreak(now: now) && snoozesRemaining > 0
    }

    var upcomingBreakKind: BreakKind {
        guard settings.longBreakEnabled else { return .short }
        return snapshot.completedShortBreaks + 1 >= max(1, settings.longBreakFrequency) ? .long : .short
    }

    func duration(for kind: BreakKind) -> TimeInterval {
        switch kind {
        case .short, .manual: settings.shortBreakDuration
        case .long: settings.longBreakDuration
        case .planned: settings.plannedBreaks.first?.duration ?? settings.longBreakDuration
        }
    }

    func stats(now: Date) -> DashboardStats {
        BreakMath.stats(records: records, snapshot: snapshot, now: now, calendar: calendar)
    }

    func nextPlannedBreak(after now: Date) -> (PlannedBreak, Date)? {
        BreakMath.nextPlannedBreak(settings: settings, after: now, calendar: calendar)
    }

    // MARK: - Tick

    mutating func tick(now: Date, inputs: Inputs = Inputs()) -> [Event] {
        var events: [Event] = []
        resetDailyCountersIfNeeded(now: now)

        if snapshot.phase == .breaking {
            if now >= snapshot.breakEndsAt ?? .distantFuture {
                events += endBreak(completed: true, now: now)
            }
            clearWellnessCadence()
            return events
        }

        if snapshot.phase == .paused, snapshot.pauseReason == .manual, let until = snapshot.pausedUntil, now >= until {
            events += resume(now: now)
        }

        events += applySmartPause(signals: inputs.signals, now: now)
        events += applyIdle(seconds: inputs.idleSeconds, now: now)

        guard snapshot.phase != .paused else {
            clearWellnessCadence()
            return events
        }

        guard settings.officeHours.contains(now, calendar: calendar) else {
            if snapshot.nextBreakAt <= now {
                snapshot.focusStartedAt = now
                snapshot.nextBreakAt = now.addingTimeInterval(settings.workInterval)
            }
            if snapshot.phase == .headsUp { snapshot.phase = .focusing }
            clearWellnessCadence()
            return events
        }

        if let (planned, occurrence) = duePlannedBreak(at: now) {
            snapshot.deliveredPlannedOccurrences[planned.id.uuidString] = occurrence
            events += startBreak(kind: .planned, duration: planned.duration, plannedName: planned.name, now: now)
            return events
        }

        let headsUpAt = snapshot.nextBreakAt.addingTimeInterval(-settings.reminder.headsUpLeadTime)
        if settings.reminder.headsUpEnabled,
           now >= headsUpAt,
           now < snapshot.nextBreakAt,
           snapshot.deliveredHeadsUpFor != snapshot.nextBreakAt {
            snapshot.phase = .headsUp
            snapshot.deliveredHeadsUpFor = snapshot.nextBreakAt
            events.append(.headsUp(breakAt: snapshot.nextBreakAt))
        }

        if now >= snapshot.nextBreakAt {
            events += startBreak(kind: upcomingBreakKind, now: now)
            return events
        }

        events += wellnessEvents(now: now)
        return events
    }

    // MARK: - Operations

    mutating func startBreak(kind: BreakKind = .manual, duration: TimeInterval? = nil, plannedName: String? = nil, now: Date) -> [Event] {
        guard snapshot.phase != .breaking else { return [] }
        let resolved = duration ?? self.duration(for: kind)
        snapshot.phase = .breaking
        snapshot.breakStartedAt = now
        snapshot.breakEndsAt = now.addingTimeInterval(resolved)
        snapshot.activeKind = kind
        snapshot.activePlannedBreakName = plannedName
        snapshot.pausedRemaining = nil
        snapshot.pauseReason = nil
        snapshot.pausedUntil = nil
        clearWellnessCadence()
        return [.breakStarted(kind, duration: resolved)]
    }

    mutating func endBreak(completed: Bool, now: Date) -> [Event] {
        guard snapshot.phase == .breaking else { return [] }
        let startedAt = snapshot.breakStartedAt ?? now
        let kind = snapshot.activeKind ?? .manual
        let plannedDuration = max(0, (snapshot.breakEndsAt ?? now).timeIntervalSince(startedAt))
        appendRecord(BreakRecord(
            startedAt: startedAt,
            endedAt: now,
            plannedDuration: plannedDuration,
            kind: kind,
            completed: completed,
            skipped: !completed
        ))
        if completed {
            switch kind {
            case .short: snapshot.completedShortBreaks += 1
            case .long: snapshot.completedShortBreaks = 0
            case .planned, .manual: break
            }
        }
        startFocusInterval(at: now)
        clearActiveBreak()
        return [.breakEnded(completed: completed)]
    }

    mutating func skipActiveBreak(now: Date) -> [Event] {
        guard snapshot.phase == .breaking, canSkipBreak(now: now) else { return [] }
        return endBreak(completed: false, now: now)
    }

    /// Postpones the upcoming break, or (when allowed) the break that is running. Uses one daily snooze.
    /// A snoozed active break is not recorded as skipped.
    mutating func snooze(minutes: Int, now: Date) -> [Event] {
        resetDailyCountersIfNeeded(now: now)
        guard minutes > 0, snoozesRemaining > 0 else { return [] }
        let duringBreak = snapshot.phase == .breaking
        switch snapshot.phase {
        case .breaking:
            guard canSkipBreak(now: now) else { return [] }
            clearActiveBreak()
        case .paused:
            return []
        case .focusing, .headsUp:
            break
        }
        snapshot.snoozesUsedToday += 1
        snapshot.phase = .focusing
        snapshot.nextBreakAt = now.addingTimeInterval(TimeInterval(minutes * 60))
        snapshot.deliveredHeadsUpFor = nil
        return [.breakSnoozed(minutes: minutes, duringBreak: duringBreak)]
    }

    /// Records the upcoming break as skipped and starts a new focus interval. Not allowed in Hardcore.
    mutating func skipUpcomingBreak(now: Date) -> [Event] {
        guard canSkipUpcomingBreak, snapshot.phase == .focusing || snapshot.phase == .headsUp else { return [] }
        let kind = upcomingBreakKind
        appendRecord(BreakRecord(
            startedAt: now,
            endedAt: now,
            plannedDuration: duration(for: kind),
            kind: kind,
            completed: false,
            skipped: true
        ))
        startFocusInterval(at: now)
        return [.upcomingBreakSkipped]
    }

    mutating func pause(reason: PauseReason = .manual, until: Date? = nil, now: Date, creditingIdle idle: TimeInterval = 0) -> [Event] {
        switch snapshot.phase {
        case .breaking:
            return []
        case .paused:
            // A manual pause overrides an automatic one, so it is not lifted when the signal ends.
            guard reason == .manual, snapshot.pauseReason != .manual else { return [] }
            snapshot.pauseReason = .manual
            snapshot.pausedUntil = until
            return [.paused(.manual)]
        case .focusing, .headsUp:
            snapshot.pausedRemaining = min(settings.workInterval, nextBreakRemaining(now: now) + max(0, idle))
            snapshot.phase = .paused
            snapshot.pauseReason = reason
            snapshot.pausedUntil = reason == .manual ? until : nil
            snapshot.deliveredHeadsUpFor = nil
            return [.paused(reason)]
        }
    }

    mutating func resume(now: Date) -> [Event] {
        guard snapshot.phase == .paused else { return [] }
        let reason = snapshot.pauseReason ?? .manual
        let remaining = min(settings.workInterval, snapshot.pausedRemaining ?? settings.workInterval)
        snapshot.phase = .focusing
        snapshot.focusStartedAt = now.addingTimeInterval(-(settings.workInterval - remaining))
        snapshot.nextBreakAt = now.addingTimeInterval(remaining)
        snapshot.pausedRemaining = nil
        snapshot.pauseReason = nil
        snapshot.pausedUntil = nil
        return [.resumed(reason)]
    }

    /// Clears today's history and counters.
    mutating func resetToday(now: Date) {
        let start = calendar.startOfDay(for: now)
        records.removeAll { $0.startedAt >= start }
        snapshot.snoozesUsedToday = 0
        snapshot.snoozeDay = start
        snapshot.completedShortBreaks = 0
    }

    /// Repairs a snapshot loaded after a relaunch. Returns true when a restored break is still running.
    @discardableResult
    mutating func reconcileRestoredState(now: Date) -> Bool {
        if snapshot.phase == .breaking {
            if let end = snapshot.breakEndsAt, end > now { return true }
            clearActiveBreak()
            startFocusInterval(at: now)
            return false
        }
        if snapshot.phase == .paused, snapshot.pauseReason?.isAutomatic == true {
            // Automatic pauses are re-derived from live signals after launch.
            _ = resume(now: now)
        } else if snapshot.phase == .headsUp {
            snapshot.phase = .focusing
        }
        if snapshot.phase != .paused, snapshot.nextBreakAt < now.addingTimeInterval(-settings.workInterval) {
            startFocusInterval(at: now)
        }
        return false
    }

    mutating func normalizeSettings() {
        settings.workInterval = max(60, settings.workInterval)
        settings.shortBreakDuration = max(5, settings.shortBreakDuration)
        settings.longBreakDuration = max(60, settings.longBreakDuration)
        settings.longBreakFrequency = max(1, settings.longBreakFrequency)
        settings.snoozesAllowedPerDay = max(0, settings.snoozesAllowedPerDay)
        settings.smartPause.gracePeriod = max(0, settings.smartPause.gracePeriod)
        settings.desktop.idle.pauseAfter = max(15, settings.desktop.idle.pauseAfter)
        settings.desktop.idle.resetAfter = max(settings.desktop.idle.pauseAfter, settings.desktop.idle.resetAfter)
        settings.wellness.blinkInterval = max(60, settings.wellness.blinkInterval)
        settings.wellness.postureInterval = max(60, settings.wellness.postureInterval)
    }

    // MARK: - Smart pause and idle

    func isEnabled(_ signal: PauseReason) -> Bool {
        switch signal {
        case .meeting: settings.smartPause.meetingsAndCalls
        case .media: settings.smartPause.mediaPlayback
        case .app: settings.smartPause.deepFocusApps
        case .game: settings.smartPause.games
        case .focus: settings.smartPause.focusMode
        case .idle: settings.desktop.idle.isEnabled
        case .manual: true
        }
    }

    private static let signalPriority: [PauseReason] = [.meeting, .media, .game, .app]

    private mutating func applySmartPause(signals: Set<PauseReason>, now: Date) -> [Event] {
        let active = Self.signalPriority.first { signals.contains($0) && isEnabled($0) }
        if let active {
            lastSignalAt = now
            switch snapshot.phase {
            case .focusing, .headsUp:
                return pause(reason: active, now: now)
            case .paused where snapshot.pauseReason == .idle || (snapshot.pauseReason?.isSmartPause == true && snapshot.pauseReason != active):
                snapshot.pauseReason = active
                return [.paused(active)]
            case .paused, .breaking:
                return []
            }
        }
        guard snapshot.phase == .paused, snapshot.pauseReason?.isSmartPause == true else { return [] }
        if let last = lastSignalAt, now.timeIntervalSince(last) < settings.smartPause.gracePeriod {
            return []
        }
        lastSignalAt = nil
        return resume(now: now)
    }

    private mutating func applyIdle(seconds idle: TimeInterval, now: Date) -> [Event] {
        let idleSettings = settings.desktop.idle
        guard idleSettings.isEnabled else {
            if snapshot.phase == .paused, snapshot.pauseReason == .idle { return resume(now: now) }
            return []
        }
        switch snapshot.phase {
        case .focusing, .headsUp:
            guard idle >= idleSettings.pauseAfter else { return [] }
            // The timer kept counting while the user was already away; give that time back.
            var events = pause(reason: .idle, now: now, creditingIdle: idle)
            if idle >= idleSettings.resetAfter {
                snapshot.pausedRemaining = settings.workInterval
                events.append(.focusReset)
            }
            return events
        case .paused where snapshot.pauseReason == .idle:
            if idle < idleSettings.pauseAfter {
                return resume(now: now)
            }
            if idle >= idleSettings.resetAfter, snapshot.pausedRemaining != settings.workInterval {
                snapshot.pausedRemaining = settings.workInterval
                return [.focusReset]
            }
            return []
        case .paused, .breaking:
            return []
        }
    }

    // MARK: - Wellness

    private mutating func wellnessEvents(now: Date) -> [Event] {
        guard snapshot.phase == .focusing else { return [] }
        // Do not compete with an imminent break.
        let quietWindow = max(60, settings.reminder.headsUpEnabled ? settings.reminder.headsUpLeadTime : 0)
        let deferNudges = nextBreakRemaining(now: now) <= quietWindow
        var events: [Event] = []
        let wellness = settings.wellness

        if wellness.blinkEnabled {
            if let last = lastBlinkAt {
                if !deferNudges, now.timeIntervalSince(last) >= wellness.blinkInterval {
                    lastBlinkAt = now
                    events.append(.wellness(.blink))
                }
            } else {
                lastBlinkAt = now
            }
        } else {
            lastBlinkAt = nil
        }

        if wellness.postureEnabled {
            if let last = lastPostureAt {
                if !deferNudges, events.isEmpty, now.timeIntervalSince(last) >= wellness.postureInterval {
                    lastPostureAt = now
                    events.append(.wellness(.posture))
                }
            } else {
                lastPostureAt = now
            }
        } else {
            lastPostureAt = nil
        }
        return events
    }

    private mutating func clearWellnessCadence() {
        lastBlinkAt = nil
        lastPostureAt = nil
    }

    // MARK: - Helpers

    private mutating func startFocusInterval(at now: Date) {
        snapshot.phase = .focusing
        snapshot.focusStartedAt = now
        snapshot.nextBreakAt = now.addingTimeInterval(settings.workInterval)
        snapshot.deliveredHeadsUpFor = nil
        snapshot.pausedRemaining = nil
        snapshot.pauseReason = nil
        snapshot.pausedUntil = nil
    }

    private mutating func clearActiveBreak() {
        snapshot.breakStartedAt = nil
        snapshot.breakEndsAt = nil
        snapshot.activeKind = nil
        snapshot.activePlannedBreakName = nil
    }

    private mutating func appendRecord(_ record: BreakRecord) {
        records.append(record)
        if records.count > BreakRecord.historyLimit {
            records.removeFirst(records.count - BreakRecord.historyLimit)
        }
    }

    private func duePlannedBreak(at date: Date) -> (PlannedBreak, Date)? {
        for planned in settings.plannedBreaks where planned.isEnabled {
            guard let occurrence = planned.occurrence(on: date, calendar: calendar) else { continue }
            let alreadyDelivered = snapshot.deliveredPlannedOccurrences[planned.id.uuidString]
            if date >= occurrence,
               date < occurrence.addingTimeInterval(60),
               alreadyDelivered.map({ !calendar.isDate($0, inSameDayAs: occurrence) }) ?? true {
                return (planned, occurrence)
            }
        }
        return nil
    }

    private mutating func resetDailyCountersIfNeeded(now: Date) {
        let today = calendar.startOfDay(for: now)
        guard snapshot.snoozeDay != today else { return }
        snapshot.snoozeDay = today
        snapshot.snoozesUsedToday = 0
        snapshot.deliveredPlannedOccurrences = [:]
    }
}
