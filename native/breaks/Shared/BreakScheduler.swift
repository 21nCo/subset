import Foundation

/// The platform-independent break schedule: focus intervals, heads-up, breaks, snoozes, pauses,
/// smart pause, idle handling, blink and posture cadence, and hard stops.
///
/// It is a value type with no timers, UI, or system APIs. A platform host (the iOS `BreakEngine` or the
/// macOS `MacBreakController`) calls `tick(now:inputs:)` about once a second, feeds in the activity signals
/// its platform can observe, and performs the returned events (show an overlay, apply a shield, play a sound).
struct BreakScheduler: Sendable {
    enum Event: Equatable, Sendable {
        case headsUp(breakAt: Date)
        /// A shown heads-up no longer applies (for example, office hours ended); hosts hide it.
        case headsUpCancelled
        case breakStarted(BreakKind, duration: TimeInterval)
        case breakEnded(completed: Bool)
        case breakSnoozed(minutes: Int, duringBreak: Bool)
        case upcomingBreakSkipped
        case paused(PauseReason)
        case resumed(PauseReason)
        /// The user was away long enough that the absence counts as rest; the next interval starts fresh.
        case focusReset
        case wellness(WellnessReminder)
        /// A hard stop starts soon. `waitingForCall` is true when a call is running and the stop will wait for it.
        case hardStopWarning(id: UUID, startsAt: Date, waitingForCall: Bool)
        /// A hard stop blocks the screen until `endsAt`, or until dismissed when nil.
        case hardStopStarted(id: UUID, endsAt: Date?)
        /// The stop is hidden until `until`; its end does not move.
        case hardStopExtended(id: UUID, until: Date)
        /// An extension ran out and the stop is shown again.
        case hardStopResumed(id: UUID)
        case hardStopEnded(id: UUID, reason: HardStopEndReason)
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
    /// When the focus timer last started or resumed counting. Idle time before this was never counted.
    private var countingSince: Date?

    /// The default calendar follows the user's time zone changes, so times are worked out with the current one each tick.
    init(settings: BreakSettings, snapshot: EngineSnapshot, records: [BreakRecord], calendar: Calendar = .autoupdatingCurrent) {
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

    /// Discipline levels do not apply to hard stops: a hard stop is never skipped, snoozed, or ended early.
    func canSkipBreak(now: Date) -> Bool {
        guard snapshot.activeHardStop == nil else { return false }
        return switch settings.discipline {
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
        snapshot.activeHardStop == nil && settings.allowEarlyEnd && breakProgress(now: now) >= settings.earlyEndProgress
    }

    var canSkipUpcomingBreak: Bool { settings.discipline != .hardcore && snapshot.activeHardStop == nil }

    /// True when the shown hard stop's escape hatch has an extension left.
    func canExtendHardStop(now: Date) -> Bool {
        guard let active = snapshot.activeHardStop, active.extendedUntil == nil,
              active.endsAt.map({ now < $0 }) ?? true,
              case .extend(_, let times) = active.escapeHatch else { return false }
        return active.extensionsUsed < times
    }

    /// A stop without an end can always be dismissed; one with an end only when its escape hatch allows it.
    var canDismissHardStop: Bool {
        guard let active = snapshot.activeHardStop else { return false }
        return active.endsAt == nil || active.escapeHatch == .dismissEarly
    }

    /// A break may be snoozed while it runs only when it could also be skipped, and a snooze is left.
    /// A planned break is not snoozed: the snooze would replace it with an ordinary interval break.
    func canSnoozeActiveBreak(now: Date) -> Bool {
        snapshot.phase == .breaking && snapshot.activeKind != .planned && canSkipBreak(now: now) && snoozesRemaining > 0
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
        // A hard stop's length comes from its own end, not from the break settings.
        case .hardStop: 0
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

        events += advanceHardStops(now: now, inCall: inputs.signals.contains(.meeting))
        if snapshot.activeHardStop != nil {
            // A running hard stop overrides pauses, idle, office hours, and regular and planned breaks, and
            // keeps the heads-up and nudges off. A planned break due meanwhile is dropped, not started afterwards.
            while let (planned, occurrence) = duePlannedBreak(at: now) {
                snapshot.deliveredPlannedOccurrences[planned.id.uuidString] = occurrence
            }
            clearWellnessCadence()
            return events
        }

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

        // Planned breaks run at their chosen time, inside or outside office hours.
        if let (planned, occurrence) = duePlannedBreak(at: now) {
            events += startPlannedBreak(planned, occurrence: occurrence, now: now)
            return events
        }

        guard settings.officeHours.contains(now, calendar: calendar) else {
            if snapshot.nextBreakAt <= now {
                snapshot.focusStartedAt = now
                snapshot.nextBreakAt = now.addingTimeInterval(settings.workInterval)
                countingSince = now
            }
            if snapshot.phase == .headsUp {
                snapshot.phase = .focusing
                events.append(.headsUpCancelled)
            }
            clearWellnessCadence()
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
        guard snapshot.phase != .breaking, snapshot.activeHardStop == nil, kind != .hardStop else { return [] }
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

    /// Starts today's occurrence of a planned break if it is still running, for the time that is left.
    /// Used when a background monitor reports that a planned break began (the iOS Device Activity extension).
    mutating func startPlannedBreak(id: UUID, now: Date) -> [Event] {
        guard
            snapshot.activeHardStop == nil,
            let planned = settings.plannedBreaks.first(where: { $0.id == id }),
            let occurrence = planned.occurrence(on: now, calendar: calendar),
            isUndelivered(planned, occurrence: occurrence),
            now >= occurrence,
            now < occurrence.addingTimeInterval(planned.duration)
        else { return [] }
        return startPlannedBreak(planned, occurrence: occurrence, now: now)
    }

    /// Ends a regular or planned break. A hard stop ends only through its own rules and `dismissHardStop`.
    mutating func endBreak(completed: Bool, now: Date) -> [Event] {
        guard snapshot.activeHardStop == nil else { return [] }
        return finishBreak(completed: completed, now: now)
    }

    private mutating func finishBreak(completed: Bool, now: Date) -> [Event] {
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
            skipped: !completed,
            focusDuration: max(0, startedAt.timeIntervalSince(snapshot.focusStartedAt))
        ))
        if completed {
            switch kind {
            case .short: snapshot.completedShortBreaks += 1
            case .long: snapshot.completedShortBreaks = 0
            case .planned, .manual, .hardStop: break
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
    /// Has no effect while a hard stop is running, and then uses no snooze.
    mutating func snooze(minutes: Int, now: Date) -> [Event] {
        guard snapshot.activeHardStop == nil else { return [] }
        resetDailyCountersIfNeeded(now: now)
        guard minutes > 0, snoozesRemaining > 0 else { return [] }
        let duringBreak = snapshot.phase == .breaking
        switch snapshot.phase {
        case .breaking:
            guard snapshot.activeKind != .planned, canSkipBreak(now: now) else { return [] }
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
        countingSince = now
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
            skipped: true,
            focusDuration: max(0, now.timeIntervalSince(snapshot.focusStartedAt))
        ))
        startFocusInterval(at: now)
        return [.upcomingBreakSkipped]
    }

    mutating func pause(reason: PauseReason = .manual, until: Date? = nil, now: Date, creditingIdle idle: TimeInterval = 0) -> [Event] {
        guard snapshot.activeHardStop == nil else { return [] }
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
        countingSince = now
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

    /// Repairs a snapshot loaded after a relaunch. Returns true when a restored regular or planned break is
    /// still running. A restored hard stop returns false: the next tick ends, resumes, or keeps it and reports
    /// that through its events. One-off hard stops whose date has passed are removed.
    @discardableResult
    mutating func reconcileRestoredState(now: Date) -> Bool {
        removeExpiredOnceStops(now: now)
        if snapshot.activeHardStop != nil { return false }
        if snapshot.phase == .breaking {
            let end = snapshot.breakEndsAt ?? now
            if end > now { return true }
            // The break ran its full length while the app was not running: record it as completed.
            _ = endBreak(completed: true, now: end)
            startFocusInterval(at: now)
            return false
        }
        if snapshot.phase == .paused, snapshot.pauseReason?.isAutomatic == true, snapshot.pauseReason != .focus {
            // Idle and smart pauses are re-derived from live signals after launch. A Focus pause is not:
            // it ends only when the Focus Filter reports that the Focus is off.
            _ = resume(now: now)
        } else if snapshot.phase == .headsUp {
            // Show the heads-up again on the next tick if it still applies.
            snapshot.phase = .focusing
            snapshot.deliveredHeadsUpFor = nil
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
        if settings.hardStops.count > HardStop.maximumCount {
            settings.hardStops.removeLast(settings.hardStops.count - HardStop.maximumCount)
        }
        for index in settings.hardStops.indices {
            Self.normalize(&settings.hardStops[index])
        }
    }

    private static func normalize(_ stop: inout HardStop) {
        func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T { min(range.upperBound, max(range.lowerBound, value)) }
        stop.hour = clamp(stop.hour, 0...23)
        stop.minute = clamp(stop.minute, 0...59)
        switch stop.end {
        case .at(let hour, let minute): stop.end = .at(hour: clamp(hour, 0...23), minute: clamp(minute, 0...59))
        case .after(let duration): stop.end = .after(clamp(duration, HardStop.durationRange))
        case .untilDismissed: break
        }
        if case .weekdays(let weekdays) = stop.repeats {
            stop.repeats = .weekdays(weekdays.filter((1...7).contains))
        }
        let warnings = Set(stop.warningMinutes.filter(HardStop.warningRange.contains)).sorted(by: >)
        stop.warningMinutes = Array(warnings.prefix(HardStop.maximumWarnings))
        if case .extend(let minutes, let times) = stop.escapeHatch {
            stop.escapeHatch = .extend(minutes: clamp(minutes, HardStop.extendMinutesRange), times: clamp(times, HardStop.extendTimesRange))
        }
    }

    // MARK: - Hard stops

    /// Hides the shown hard stop for the escape hatch's minutes without moving its end. Returns no events when
    /// the escape hatch has no extension left.
    mutating func extendHardStop(now: Date) -> [Event] {
        guard canExtendHardStop(now: now), var active = snapshot.activeHardStop,
              case .extend(let minutes, _) = active.escapeHatch else { return [] }
        let until = now.addingTimeInterval(TimeInterval(minutes * 60))
        active.extensionsUsed += 1
        active.extendedUntil = until
        snapshot.activeHardStop = active
        clearActiveBreak()
        snapshot.phase = .focusing
        // While hidden, the countdown shows when the stop returns or ends.
        snapshot.focusStartedAt = now
        snapshot.nextBreakAt = min(until, active.endsAt ?? until)
        countingSince = now
        return [.hardStopExtended(id: active.id, until: until)]
    }

    /// Ends the running hard stop early. Returns no events unless it lasts until dismissed or its escape hatch
    /// allows dismissing it.
    mutating func dismissHardStop(now: Date) -> [Event] {
        guard canDismissHardStop else { return [] }
        return finishHardStop(.dismissed, endedAt: now, now: now)
    }

    /// Moves hard stops forward for one tick: merges, ends, resumes, starts, misses, and warns.
    private mutating func advanceHardStops(now: Date, inCall: Bool) -> [Event] {
        var events: [Event] = []
        let stops = settings.hardStops.filter(\.isEnabled)

        // The latest due occurrence of each stop that has not been handled. One that waits for a call is held back.
        var due: [(stop: HardStop, occurrence: HardStop.Occurrence)] = []
        for stop in stops {
            let key = stop.id.uuidString
            guard let occurrence = stop.occurrences(around: now, calendar: calendar).last(where: {
                stop.isDue($0, now: now, calendar: calendar) && !isHandled(stop, start: $0.start)
            }) else { continue }
            if inCall, stop.duringCalls == .waitForCallToEnd {
                snapshot.hardStopsWaitingForCall[key] = occurrence.start
            } else {
                due.append((stop, occurrence))
            }
        }
        due.sort { $0.occurrence.start < $1.occurrence.start }

        if var active = snapshot.activeHardStop {
            // A stop that starts inside the running one joins it.
            due.removeAll { item in
                guard item.occurrence.start < active.endsAt ?? .distantFuture else { return false }
                merge(item.stop, item.occurrence, into: &active)
                return true
            }
            snapshot.activeHardStop = active
            if let end = active.endsAt, now >= end {
                events += finishHardStop(.ended, endedAt: end, now: now)
            } else if let until = active.extendedUntil, now >= until {
                snapshot.activeHardStop?.extendedUntil = nil
                showHardStop()
                events.append(.hardStopResumed(id: active.id))
            } else if active.extendedUntil == nil {
                showHardStop()
            }
        }

        events += missWaitingStops(now: now)

        if snapshot.activeHardStop == nil, let first = due.first {
            var active = ActiveHardStop(
                id: first.stop.id,
                name: first.stop.name,
                occurrence: first.occurrence.start,
                startedAt: now,
                endsAt: first.occurrence.end,
                escapeHatch: first.stop.escapeHatch
            )
            markHandled(first.stop, start: first.occurrence.start)
            for item in due.dropFirst() {
                merge(item.stop, item.occurrence, into: &active)
            }
            // A running regular or planned break ends and counts as completed; a heads-up is withdrawn.
            if snapshot.phase == .breaking {
                events += finishBreak(completed: true, now: now)
            } else if snapshot.phase == .headsUp {
                events.append(.headsUpCancelled)
            }
            snapshot.activeHardStop = active
            showHardStop()
            events.append(.hardStopStarted(id: active.id, endsAt: active.endsAt))
        }

        removeExpiredOnceStops(now: now)
        events += hardStopWarnings(stops: stops, now: now, inCall: inCall)
        pruneHardStopProgress()
        return events
    }

    /// A stop that waited for a call and whose occurrence can no longer start is missed: it is recorded and never starts.
    private mutating func missWaitingStops(now: Date) -> [Event] {
        var events: [Event] = []
        for (key, start) in snapshot.hardStopsWaitingForCall.sorted(by: { $0.value < $1.value }) {
            guard let stop = settings.hardStops.first(where: { $0.id.uuidString == key && $0.isEnabled }),
                  !isHandled(stop, start: start) else {
                snapshot.hardStopsWaitingForCall[key] = nil
                continue
            }
            let occurrence = HardStop.Occurrence(start: start, end: stop.end(forStart: start, calendar: calendar))
            guard !stop.isDue(occurrence, now: now, calendar: calendar) else { continue }
            markHandled(stop, start: start)
            let end = occurrence.end ?? now
            appendRecord(BreakRecord(
                startedAt: start,
                endedAt: end,
                plannedDuration: max(0, end.timeIntervalSince(start)),
                kind: .hardStop,
                completed: false,
                skipped: false,
                hardStopEndReason: .missed,
                extensionsUsed: 0
            ))
            removeOnceStops([stop.id])
            events.append(.hardStopEnded(id: stop.id, reason: .missed))
        }
        return events
    }

    /// Warnings are not replayed: only the latest one whose time has passed is shown, once, while the start is
    /// still ahead. A stop that will start inside the running one gets none.
    private mutating func hardStopWarnings(stops: [HardStop], now: Date, inCall: Bool) -> [Event] {
        var events: [Event] = []
        for stop in stops {
            let key = stop.id.uuidString
            guard let next = stop.occurrences(around: now, calendar: calendar).first(where: { $0.start > now }) else { continue }
            if let active = snapshot.activeHardStop, next.start < active.endsAt ?? .distantFuture { continue }
            guard let minutes = stop.warningMinutes.filter({ now >= next.start.addingTimeInterval(-TimeInterval($0 * 60)) }).min() else { continue }
            if let mark = snapshot.hardStopWarnings[key], mark.occurrence == next.start, mark.minutes <= minutes { continue }
            snapshot.hardStopWarnings[key] = HardStopWarningMark(occurrence: next.start, minutes: minutes)
            events.append(.hardStopWarning(id: stop.id, startsAt: next.start, waitingForCall: inCall && stop.duringCalls == .waitForCallToEnd))
        }
        return events
    }

    /// The stop that ends later sets the escape hatch. A stop without an end ends latest.
    private mutating func merge(_ stop: HardStop, _ occurrence: HardStop.Occurrence, into active: inout ActiveHardStop) {
        markHandled(stop, start: occurrence.start)
        if stop.id != active.id, !active.mergedIDs.contains(stop.id) {
            active.mergedIDs.append(stop.id)
        }
        let endsLater = switch (occurrence.end, active.endsAt) {
        case (nil, nil): false
        case (nil, _?): true
        case (_?, nil): false
        case let (end?, current?): end > current
        }
        if endsLater {
            active.endsAt = occurrence.end
            active.escapeHatch = stop.escapeHatch
        }
    }

    private mutating func finishHardStop(_ reason: HardStopEndReason, endedAt: Date, now: Date) -> [Event] {
        guard let active = snapshot.activeHardStop else { return [] }
        appendRecord(BreakRecord(
            startedAt: active.startedAt,
            endedAt: endedAt,
            plannedDuration: active.endsAt.map { max(0, $0.timeIntervalSince(active.startedAt)) } ?? 0,
            kind: .hardStop,
            completed: reason == .ended,
            skipped: false,
            hardStopEndReason: reason,
            extensionsUsed: active.extensionsUsed
        ))
        removeOnceStops([active.id] + active.mergedIDs)
        snapshot.activeHardStop = nil
        clearActiveBreak()
        // A fresh focus interval starts after a hard stop; a pause from before it does not come back.
        startFocusInterval(at: now)
        return [.hardStopEnded(id: active.id, reason: reason)]
    }

    /// Shows the running hard stop as a break of kind `.hardStop`, replacing any pause.
    private mutating func showHardStop() {
        guard let active = snapshot.activeHardStop else { return }
        snapshot.phase = .breaking
        snapshot.activeKind = .hardStop
        snapshot.activePlannedBreakName = active.name
        snapshot.breakStartedAt = active.startedAt
        snapshot.breakEndsAt = active.endsAt
        snapshot.pausedRemaining = nil
        snapshot.pauseReason = nil
        snapshot.pausedUntil = nil
        snapshot.deliveredHeadsUpFor = nil
    }

    private func isHandled(_ stop: HardStop, start: Date) -> Bool {
        snapshot.handledHardStops[stop.id.uuidString].map { start <= $0 } ?? false
    }

    private mutating func markHandled(_ stop: HardStop, start: Date) {
        let key = stop.id.uuidString
        snapshot.handledHardStops[key] = max(start, snapshot.handledHardStops[key] ?? start)
        snapshot.hardStopsWaitingForCall[key] = nil
    }

    private mutating func removeOnceStops(_ ids: [UUID]) {
        settings.hardStops.removeAll { $0.isOnce && ids.contains($0.id) }
    }

    /// Removes one-off stops that can no longer start, except one that is running or waiting for a call.
    private mutating func removeExpiredOnceStops(now: Date) {
        let keep = Set((snapshot.activeHardStop.map { [$0.id] + $0.mergedIDs } ?? []).map(\.uuidString))
            .union(snapshot.hardStopsWaitingForCall.keys)
        settings.hardStops.removeAll { stop in
            !keep.contains(stop.id.uuidString) && stop.isExpiredOnce(now: now, calendar: calendar)
        }
    }

    /// Drops progress kept for stops that no longer exist.
    private mutating func pruneHardStopProgress() {
        let ids = Set(settings.hardStops.map(\.id.uuidString))
        if !snapshot.hardStopWarnings.keys.allSatisfy(ids.contains) {
            snapshot.hardStopWarnings = snapshot.hardStopWarnings.filter { ids.contains($0.key) }
        }
        if !snapshot.handledHardStops.keys.allSatisfy(ids.contains) {
            snapshot.handledHardStops = snapshot.handledHardStops.filter { ids.contains($0.key) }
        }
        if !snapshot.hardStopsWaitingForCall.keys.allSatisfy(ids.contains) {
            snapshot.hardStopsWaitingForCall = snapshot.hardStopsWaitingForCall.filter { ids.contains($0.key) }
        }
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
            // The timer kept counting while the user was already away; give that time back, but only the
            // part the timer actually counted (not time spent in an earlier pause).
            let counted = min(idle, max(0, now.timeIntervalSince(countingSince ?? snapshot.focusStartedAt)))
            var events = pause(reason: .idle, now: now, creditingIdle: counted)
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
        countingSince = now
    }

    private mutating func startPlannedBreak(_ planned: PlannedBreak, occurrence: Date, now: Date) -> [Event] {
        snapshot.deliveredPlannedOccurrences[planned.id.uuidString] = occurrence
        // A late start (the host was asleep or suspended at the start time) gets only the time that is left.
        let remaining = occurrence.addingTimeInterval(planned.duration).timeIntervalSince(now)
        return startBreak(kind: .planned, duration: max(1, min(planned.duration, remaining)), plannedName: planned.name, now: now)
    }

    private func isUndelivered(_ planned: PlannedBreak, occurrence: Date) -> Bool {
        snapshot.deliveredPlannedOccurrences[planned.id.uuidString].map { !calendar.isDate($0, inSameDayAs: occurrence) } ?? true
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

    /// A planned break is due from its start time until its scheduled end, so one missed by a host that was
    /// asleep or suspended still starts (for the time left) instead of being dropped for the day.
    private func duePlannedBreak(at date: Date) -> (PlannedBreak, Date)? {
        for planned in settings.plannedBreaks where planned.isEnabled {
            guard let occurrence = planned.occurrence(on: date, calendar: calendar) else { continue }
            if date >= occurrence,
               date < occurrence.addingTimeInterval(max(60, planned.duration)),
               isUndelivered(planned, occurrence: occurrence) {
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
