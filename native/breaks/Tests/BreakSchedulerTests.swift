import XCTest
#if os(iOS)
@testable import Breaks
#endif
// On macOS, the BreaksMacTests bundle compiles the shared sources directly, so no import is needed.

final class BreakSchedulerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Monday 10 August 2026, 10:00 UTC.
    private var t0: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10))!
    }

    private func makeScheduler(_ configure: (inout BreakSettings) -> Void = { _ in }) -> BreakScheduler {
        var settings = BreakSettings()
        settings.officeHours.isEnabled = false
        settings.plannedBreaks = []
        settings.workInterval = 20 * 60
        settings.shortBreakDuration = 20
        settings.wellness.blinkEnabled = false
        settings.wellness.postureEnabled = false
        configure(&settings)
        let snapshot = EngineSnapshot(
            phase: .focusing,
            focusStartedAt: t0,
            nextBreakAt: t0.addingTimeInterval(settings.workInterval),
            snoozeDay: calendar.startOfDay(for: t0)
        )
        return BreakScheduler(settings: settings, snapshot: snapshot, records: [], calendar: calendar)
    }

    /// Ticks once a second over `seconds`, starting one second after `start`. Returns every event.
    @discardableResult
    private func run(
        _ scheduler: inout BreakScheduler,
        from start: Date,
        seconds: Int,
        inputs: (Date) -> BreakScheduler.Inputs = { _ in .init() }
    ) -> [BreakScheduler.Event] {
        var events: [BreakScheduler.Event] = []
        for second in 1...seconds {
            let now = start.addingTimeInterval(TimeInterval(second))
            events += scheduler.tick(now: now, inputs: inputs(now))
        }
        return events
    }

    // MARK: - Interval breaks

    func testHeadsUpThenBreakThenCompletion() {
        var scheduler = makeScheduler()
        let events = run(&scheduler, from: t0, seconds: 20 * 60 + 25)

        XCTAssertEqual(events.filter { if case .headsUp = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(events.contains(.breakStarted(.short, duration: 20)))
        XCTAssertTrue(events.contains(.breakEnded(completed: true)))
        XCTAssertEqual(scheduler.phase, .focusing)
        XCTAssertEqual(scheduler.records.count, 1)
        XCTAssertEqual(scheduler.records.first?.completed, true)
        XCTAssertEqual(scheduler.records.first?.kind, .short)
    }

    func testHeadsUpRespectsLeadTimeAndToggle() {
        // A non-default lead time, so a hard-coded 60 seconds would fail.
        var scheduler = makeScheduler { $0.reminder.headsUpLeadTime = 120 }
        XCTAssertTrue(run(&scheduler, from: t0, seconds: 20 * 60 - 121).isEmpty)
        XCTAssertEqual(scheduler.tick(now: t0.addingTimeInterval(20 * 60 - 120)), [.headsUp(breakAt: t0.addingTimeInterval(20 * 60))])
        XCTAssertEqual(scheduler.phase, .headsUp)

        var silent = makeScheduler { $0.reminder.headsUpEnabled = false }
        let events = run(&silent, from: t0, seconds: 20 * 60)
        XCTAssertFalse(events.contains { if case .headsUp = $0 { true } else { false } })
    }

    func testLongBreakCadenceRepeatsInsteadOfStickingOnLong() {
        var scheduler = makeScheduler {
            $0.longBreakEnabled = true
            $0.longBreakFrequency = 3
            $0.longBreakDuration = 60
        }
        var kinds: [BreakKind] = []
        var now = t0
        for _ in 0..<6 {
            kinds.append(scheduler.upcomingBreakKind)
            _ = scheduler.startBreak(kind: scheduler.upcomingBreakKind, now: now)
            now = now.addingTimeInterval(scheduler.duration(for: kinds.last!))
            _ = scheduler.endBreak(completed: true, now: now)
        }
        XCTAssertEqual(kinds, [.short, .short, .long, .short, .short, .long])
    }

    func testOfficeHoursHoldBreaks() {
        var scheduler = makeScheduler {
            $0.officeHours = OfficeHours(isEnabled: true, startHour: 12, startMinute: 0, endHour: 18, endMinute: 0, weekdays: [2, 3, 4, 5, 6])
        }
        let events = run(&scheduler, from: t0, seconds: 25 * 60)
        XCTAssertFalse(events.contains { if case .breakStarted = $0 { true } else { false } })
        XCTAssertEqual(scheduler.phase, .focusing)
    }

    func testPlannedBreakStartsOnceAtItsTime() {
        let start = t0
        var scheduler = makeScheduler {
            $0.workInterval = 120 * 60
            $0.plannedBreaks = [PlannedBreak(name: "Walk", symbol: "figure.walk", hour: 10, minute: 5, duration: 300, weekdays: [2], isEnabled: true)]
        }
        let events = run(&scheduler, from: start, seconds: 5 * 60 + 30)
        XCTAssertEqual(events.filter { $0 == .breakStarted(.planned, duration: 300) }.count, 1)
        XCTAssertEqual(scheduler.snapshot.activePlannedBreakName, "Walk")
    }

    func testPlannedBreakRunsOutsideOfficeHours() {
        var scheduler = makeScheduler {
            $0.officeHours = OfficeHours(isEnabled: true, startHour: 12, startMinute: 0, endHour: 18, endMinute: 0, weekdays: [2, 3, 4, 5, 6])
            $0.plannedBreaks = [PlannedBreak(name: "Walk", symbol: "figure.walk", hour: 10, minute: 5, duration: 300, weekdays: [2], isEnabled: true)]
        }
        let events = run(&scheduler, from: t0, seconds: 5 * 60 + 1)
        XCTAssertTrue(events.contains(.breakStarted(.planned, duration: 300)))
    }

    func testLatePlannedBreakGetsOnlyTheTimeLeft() {
        let planned = PlannedBreak(name: "Walk", symbol: "figure.walk", hour: 10, minute: 0, duration: 900, weekdays: [2], isEnabled: true)
        // A host that was asleep at 10:00 ticks again at 10:10.
        var scheduler = makeScheduler { $0.workInterval = 120 * 60; $0.plannedBreaks = [planned] }
        XCTAssertEqual(scheduler.tick(now: t0.addingTimeInterval(600)), [.breakStarted(.planned, duration: 300)])

        // A monitor-reported start joins the same occurrence once, for the time left.
        var joined = makeScheduler { $0.workInterval = 120 * 60; $0.plannedBreaks = [planned] }
        XCTAssertEqual(joined.startPlannedBreak(id: planned.id, now: t0.addingTimeInterval(840)), [.breakStarted(.planned, duration: 60)])
        _ = joined.endBreak(completed: true, now: t0.addingTimeInterval(900))
        XCTAssertTrue(joined.startPlannedBreak(id: planned.id, now: t0.addingTimeInterval(899)).isEmpty)
        // After its scheduled end it does not start at all.
        var expired = makeScheduler { $0.plannedBreaks = [planned] }
        XCTAssertTrue(expired.startPlannedBreak(id: planned.id, now: t0.addingTimeInterval(901)).isEmpty)
    }

    func testHeadsUpIsCancelledWhenOfficeHoursEnd() {
        var scheduler = makeScheduler {
            $0.officeHours = OfficeHours(isEnabled: true, startHour: 8, startMinute: 0, endHour: 10, endMinute: 20, weekdays: [2])
        }
        // The heads-up for the 10:20 break shows at 10:19; office hours end at 10:20.
        let events = run(&scheduler, from: t0, seconds: 20 * 60)
        XCTAssertTrue(events.contains(.headsUp(breakAt: t0.addingTimeInterval(20 * 60))))
        XCTAssertEqual(events.last, .headsUpCancelled)
        XCTAssertEqual(scheduler.phase, .focusing)
        XCTAssertFalse(events.contains { if case .breakStarted = $0 { true } else { false } })
    }

    // MARK: - Discipline, skip, and snooze

    func testDisciplineControlsSkipping() {
        var casual = makeScheduler { $0.discipline = .casual }
        _ = casual.startBreak(now: t0)
        XCTAssertEqual(casual.skipActiveBreak(now: t0), [.breakEnded(completed: false)])
        XCTAssertEqual(casual.records.last?.skipped, true)

        var balanced = makeScheduler { $0.discipline = .balanced }
        _ = balanced.startBreak(now: t0)
        XCTAssertTrue(balanced.skipActiveBreak(now: t0.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(balanced.skipAvailableIn(now: t0.addingTimeInterval(2)), 3)
        XCTAssertEqual(balanced.skipActiveBreak(now: t0.addingTimeInterval(5)), [.breakEnded(completed: false)])

        var hardcore = makeScheduler { $0.discipline = .hardcore }
        _ = hardcore.startBreak(now: t0)
        XCTAssertTrue(hardcore.skipActiveBreak(now: t0.addingTimeInterval(19)).isEmpty)
        XCTAssertTrue(hardcore.snooze(minutes: 5, now: t0.addingTimeInterval(10)).isEmpty)
        XCTAssertTrue(hardcore.skipUpcomingBreak(now: t0).isEmpty)
        XCTAssertEqual(hardcore.phase, .breaking)
    }

    func testEarlyEndRequiresProgress() {
        var scheduler = makeScheduler { $0.shortBreakDuration = 100 }
        _ = scheduler.startBreak(kind: .short, now: t0)
        XCTAssertFalse(scheduler.canEndEarly(now: t0.addingTimeInterval(50)))
        XCTAssertTrue(scheduler.canEndEarly(now: t0.addingTimeInterval(80)))
    }

    func testSnoozeUsesDailyAllowanceAndResetsNextDay() {
        var scheduler = makeScheduler { $0.snoozesAllowedPerDay = 2 }
        XCTAssertEqual(scheduler.snooze(minutes: 5, now: t0), [.breakSnoozed(minutes: 5, duringBreak: false)])
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, t0.addingTimeInterval(300))
        _ = scheduler.snooze(minutes: 1, now: t0)
        XCTAssertEqual(scheduler.snoozesRemaining, 0)
        XCTAssertTrue(scheduler.snooze(minutes: 1, now: t0).isEmpty)

        let tomorrow = t0.addingTimeInterval(24 * 60 * 60)
        XCTAssertFalse(scheduler.snooze(minutes: 1, now: tomorrow).isEmpty)
        XCTAssertEqual(scheduler.snoozesRemaining, 1)
    }

    func testSnoozingActiveBreakIsNotRecordedAsSkip() {
        var scheduler = makeScheduler { $0.discipline = .casual }
        _ = scheduler.startBreak(kind: .short, now: t0)
        XCTAssertEqual(scheduler.snooze(minutes: 1, now: t0.addingTimeInterval(3)), [.breakSnoozed(minutes: 1, duringBreak: true)])
        XCTAssertEqual(scheduler.phase, .focusing)
        XCTAssertTrue(scheduler.records.isEmpty)
        XCTAssertNil(scheduler.snapshot.breakStartedAt)
        XCTAssertEqual(scheduler.snapshot.snoozesUsedToday, 1)
    }

    func testRunningPlannedBreakCannotBeSnoozed() {
        var scheduler = makeScheduler { $0.discipline = .casual }
        _ = scheduler.startBreak(kind: .planned, duration: 900, plannedName: "Walk", now: t0)
        XCTAssertFalse(scheduler.canSnoozeActiveBreak(now: t0.addingTimeInterval(10)))
        XCTAssertTrue(scheduler.snooze(minutes: 1, now: t0.addingTimeInterval(10)).isEmpty)
        XCTAssertEqual(scheduler.phase, .breaking)
    }

    func testSkipUpcomingBreakRecordsSkipAndRestartsInterval() {
        var scheduler = makeScheduler { $0.discipline = .balanced }
        let now = t0.addingTimeInterval(600)
        XCTAssertEqual(scheduler.skipUpcomingBreak(now: now), [.upcomingBreakSkipped])
        XCTAssertEqual(scheduler.records.last?.skipped, true)
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, now.addingTimeInterval(20 * 60))
    }

    // MARK: - Pause, idle, and smart pause

    func testTimedManualPauseResumesWithRemainingTime() {
        var scheduler = makeScheduler()
        let pausedAt = t0.addingTimeInterval(5 * 60)
        XCTAssertEqual(scheduler.pause(until: pausedAt.addingTimeInterval(60), now: pausedAt), [.paused(.manual)])
        XCTAssertEqual(scheduler.nextBreakRemaining(now: pausedAt.addingTimeInterval(30)), 15 * 60)
        let events = run(&scheduler, from: pausedAt, seconds: 60)
        XCTAssertTrue(events.contains(.resumed(.manual)))
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, pausedAt.addingTimeInterval(60 + 15 * 60))
    }

    func testIdlePausesCreditsAbsenceAndResumes() {
        var scheduler = makeScheduler()
        // Active for 5 minutes, then away for 90 seconds.
        let leftAt = t0.addingTimeInterval(5 * 60)
        let events = run(&scheduler, from: leftAt, seconds: 90) { now in
            .init(idleSeconds: now.timeIntervalSince(leftAt))
        }
        XCTAssertTrue(events.contains(.paused(.idle)))
        // Paused at 60 s idle with the 60 s already counted given back: 15 minutes remain.
        XCTAssertEqual(scheduler.snapshot.pausedRemaining, 15 * 60)

        let back = leftAt.addingTimeInterval(91)
        XCTAssertEqual(scheduler.tick(now: back, inputs: .init(idleSeconds: 0)), [.resumed(.idle)])
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, back.addingTimeInterval(15 * 60))
    }

    func testLongAbsenceResetsFocusInterval() {
        var scheduler = makeScheduler()
        let leftAt = t0.addingTimeInterval(15 * 60)
        let events = run(&scheduler, from: leftAt, seconds: 6 * 60) { now in
            .init(idleSeconds: now.timeIntervalSince(leftAt))
        }
        XCTAssertTrue(events.contains(.focusReset))
        XCTAssertFalse(events.contains { if case .breakStarted = $0 { true } else { false } })
        let back = leftAt.addingTimeInterval(6 * 60 + 1)
        _ = scheduler.tick(now: back, inputs: .init(idleSeconds: 1))
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, back.addingTimeInterval(20 * 60))
    }

    func testIdleAfterSmartPauseCreditsOnlyCountedTime() {
        var scheduler = makeScheduler { $0.smartPause.gracePeriod = 0 }
        // 5 minutes of focus, then a 10-minute call; there was no input for its last 4 minutes.
        let callAt = t0.addingTimeInterval(5 * 60)
        XCTAssertEqual(scheduler.tick(now: callAt, inputs: .init(signals: [.meeting])), [.paused(.meeting)])
        let ended = callAt.addingTimeInterval(10 * 60)
        let events = scheduler.tick(now: ended, inputs: .init(idleSeconds: 4 * 60))
        XCTAssertEqual(events, [.resumed(.meeting), .paused(.idle)])
        // The timer was frozen during the call, so none of those 4 idle minutes is given back.
        XCTAssertEqual(scheduler.snapshot.pausedRemaining, 15 * 60)
    }

    func testIdleIgnoredWhenDisabled() {
        var scheduler = makeScheduler { $0.desktop.idle.isEnabled = false }
        let events = run(&scheduler, from: t0, seconds: 120) { _ in .init(idleSeconds: 600) }
        XCTAssertTrue(events.isEmpty)
    }

    func testMeetingPausesAndResumesAfterGracePeriod() {
        var scheduler = makeScheduler { $0.smartPause.gracePeriod = 30 }
        let meeting = t0.addingTimeInterval(19 * 60)
        XCTAssertEqual(scheduler.tick(now: meeting, inputs: .init(signals: [.meeting])), [.paused(.meeting)])
        // A long call: the break that was due does not start, and idle does not replace the reason.
        let during = run(&scheduler, from: meeting, seconds: 10 * 60) { _ in .init(idleSeconds: 400, signals: [.meeting]) }
        XCTAssertTrue(during.isEmpty)
        XCTAssertEqual(scheduler.pauseReasonForTest, .meeting)

        let ended = meeting.addingTimeInterval(10 * 60)
        let afterCall = run(&scheduler, from: ended, seconds: 29)
        XCTAssertTrue(afterCall.isEmpty, "Still within the grace period")
        let resumed = scheduler.tick(now: ended.addingTimeInterval(30))
        XCTAssertEqual(resumed.first, .resumed(.meeting))
        // The minute that was left when the call started is kept, so the heads-up shows again.
        XCTAssertEqual(scheduler.nextBreakRemaining(now: ended.addingTimeInterval(30)), 60)
        XCTAssertTrue(resumed.contains { if case .headsUp = $0 { true } else { false } })
    }

    func testDisabledSignalsAreIgnored() {
        var scheduler = makeScheduler {
            $0.smartPause.mediaPlayback = false
            $0.smartPause.games = false
        }
        XCTAssertTrue(scheduler.tick(now: t0.addingTimeInterval(1), inputs: .init(signals: [.media, .game])).isEmpty)
        XCTAssertEqual(scheduler.phase, .focusing)
    }

    func testManualPauseIsNotLiftedBySignalEnding() {
        var scheduler = makeScheduler { $0.smartPause.gracePeriod = 0 }
        XCTAssertEqual(scheduler.tick(now: t0.addingTimeInterval(1), inputs: .init(signals: [.meeting])), [.paused(.meeting)])
        XCTAssertEqual(scheduler.pause(now: t0.addingTimeInterval(2)), [.paused(.manual)])
        let events = run(&scheduler, from: t0.addingTimeInterval(2), seconds: 10)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(scheduler.phase, .paused)
    }

    func testSignalDoesNotInterruptRunningBreak() {
        var scheduler = makeScheduler()
        _ = scheduler.startBreak(kind: .short, now: t0)
        XCTAssertTrue(scheduler.tick(now: t0.addingTimeInterval(1), inputs: .init(idleSeconds: 120, signals: [.meeting])).isEmpty)
        XCTAssertEqual(scheduler.phase, .breaking)
    }

    // MARK: - Wellness

    func testBlinkAndPostureCadence() {
        var scheduler = makeScheduler {
            $0.workInterval = 60 * 60
            $0.wellness.blinkEnabled = true
            $0.wellness.blinkInterval = 10 * 60
            $0.wellness.postureEnabled = true
            $0.wellness.postureInterval = 30 * 60
        }
        let events = run(&scheduler, from: t0, seconds: 31 * 60)
        let blinks = events.filter { $0 == .wellness(.blink) }.count
        let postures = events.filter { $0 == .wellness(.posture) }.count
        XCTAssertEqual(blinks, 3)
        XCTAssertEqual(postures, 1)
    }

    func testWellnessWaitsWhilePausedAndNearBreaks() {
        var scheduler = makeScheduler {
            $0.workInterval = 12 * 60
            $0.wellness.blinkEnabled = true
            $0.wellness.blinkInterval = 11 * 60 + 30
        }
        // The blink would fall 30 s before the break, inside the heads-up window, so it waits.
        let events = run(&scheduler, from: t0, seconds: 12 * 60 - 1)
        XCTAssertFalse(events.contains(.wellness(.blink)))

        var paused = makeScheduler {
            $0.wellness.blinkEnabled = true
            $0.wellness.blinkInterval = 2 * 60
        }
        _ = paused.pause(now: t0)
        XCTAssertFalse(run(&paused, from: t0, seconds: 5 * 60).contains(.wellness(.blink)))
    }

    // MARK: - Persistence and restore

    func testRestoredExpiredBreakReturnsToFocus() {
        var scheduler = makeScheduler()
        _ = scheduler.startBreak(kind: .short, now: t0)
        XCTAssertTrue(scheduler.reconcileRestoredState(now: t0.addingTimeInterval(5)))
        XCTAssertFalse(scheduler.reconcileRestoredState(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(scheduler.phase, .focusing)
        XCTAssertNil(scheduler.snapshot.breakEndsAt)
        // The break ran its full length while the app was not running, so it counts as completed.
        XCTAssertEqual(scheduler.records.count, 1)
        XCTAssertEqual(scheduler.records.first?.completed, true)
        XCTAssertEqual(scheduler.records.first?.endedAt, t0.addingTimeInterval(20))
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, t0.addingTimeInterval(60 + 20 * 60))
    }

    func testRestoredFocusPauseIsKept() {
        var scheduler = makeScheduler()
        _ = scheduler.pause(reason: .focus, now: t0.addingTimeInterval(1))
        scheduler.reconcileRestoredState(now: t0.addingTimeInterval(2))
        XCTAssertEqual(scheduler.phase, .paused)
        XCTAssertEqual(scheduler.pauseReasonForTest, .focus)
    }

    func testRestoredHeadsUpIsShownAgain() {
        var scheduler = makeScheduler()
        let headsUpAt = t0.addingTimeInterval(20 * 60 - 60)
        XCTAssertEqual(scheduler.tick(now: headsUpAt), [.headsUp(breakAt: t0.addingTimeInterval(20 * 60))])
        scheduler.reconcileRestoredState(now: headsUpAt.addingTimeInterval(5))
        XCTAssertEqual(scheduler.tick(now: headsUpAt.addingTimeInterval(6)), [.headsUp(breakAt: t0.addingTimeInterval(20 * 60))])
    }

    func testRestoredAutomaticPauseIsCleared() {
        var scheduler = makeScheduler()
        _ = scheduler.tick(now: t0.addingTimeInterval(1), inputs: .init(signals: [.meeting]))
        scheduler.reconcileRestoredState(now: t0.addingTimeInterval(2))
        XCTAssertEqual(scheduler.phase, .focusing)
    }

    func testSettingsSavedBeforeDesktopFieldsStillDecode() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BreakSettings())) as! [String: Any]
        legacy.removeValue(forKey: "desktop")
        legacy["workInterval"] = 1500
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(BreakSettings.self, from: data)
        XCTAssertEqual(decoded.workInterval, 1500)
        XCTAssertEqual(decoded.desktop, DesktopSettings())
    }

    func testHistoryIsCapped() {
        var scheduler = makeScheduler { $0.discipline = .casual }
        var now = t0
        for _ in 0..<(BreakRecord.historyLimit + 5) {
            _ = scheduler.skipUpcomingBreak(now: now)
            now = now.addingTimeInterval(1)
        }
        XCTAssertEqual(scheduler.records.count, BreakRecord.historyLimit)
    }

    // MARK: - Hard stops

    /// Monday 10 August 2026 at `hour`:`minute` UTC, plus `seconds`.
    private func at(_ hour: Int, _ minute: Int, _ seconds: Int = 0, dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 10 + dayOffset, hour: hour, minute: minute, second: seconds))!
    }

    private func hardStop(
        hour: Int = 10,
        minute: Int = 30,
        end: HardStop.End = .after(30 * 60),
        repeats: HardStop.Repeat = .weekdays([2]),
        warnings: [Int] = [],
        escapeHatch: HardStop.EscapeHatch = .none,
        duringCalls: HardStop.CallBehavior = .waitForCallToEnd
    ) -> HardStop {
        HardStop(name: "Stop", hour: hour, minute: minute, end: end, repeats: repeats, warningMinutes: warnings, escapeHatch: escapeHatch, duringCalls: duringCalls)
    }

    private func makeScheduler(stops: [HardStop], _ configure: (inout BreakSettings) -> Void = { _ in }) -> BreakScheduler {
        makeScheduler {
            $0.workInterval = 120 * 60
            $0.hardStops = stops
            configure(&$0)
        }
    }

    /// Ticks every `step` seconds from `start` (exclusive) through `end` (inclusive) and returns each event with its time.
    @discardableResult
    private func runTimed(
        _ scheduler: inout BreakScheduler,
        from start: Date,
        through end: Date,
        step: TimeInterval = 1,
        inputs: (Date) -> BreakScheduler.Inputs = { _ in .init() }
    ) -> [(Date, BreakScheduler.Event)] {
        var events: [(Date, BreakScheduler.Event)] = []
        var now = start.addingTimeInterval(step)
        while now <= end {
            events += scheduler.tick(now: now, inputs: inputs(now)).map { (now, $0) }
            now = now.addingTimeInterval(step)
        }
        return events
    }

    /// Saves and loads the state as the hosts do, then reconciles it like a relaunch.
    private func relaunch(_ scheduler: BreakScheduler, at now: Date) throws -> BreakScheduler {
        let settings = try JSONDecoder().decode(BreakSettings.self, from: JSONEncoder().encode(scheduler.settings))
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONEncoder().encode(scheduler.snapshot))
        var restored = BreakScheduler(settings: settings, snapshot: snapshot, records: scheduler.records, calendar: scheduler.calendar)
        restored.reconcileRestoredState(now: now)
        return restored
    }

    private func isHardStopEvent(_ event: BreakScheduler.Event) -> Bool {
        switch event {
        case .hardStopWarning, .hardStopStarted, .hardStopExtended, .hardStopResumed, .hardStopEnded: true
        default: false
        }
    }

    func testHardStopWarningsArriveAtEachLeadTimeOnce() {
        let stop = hardStop(warnings: [10, 2, 5])
        var scheduler = makeScheduler(stops: [stop])
        let events = runTimed(&scheduler, from: t0, through: at(10, 31))
        let warnings = events.filter { if case .hardStopWarning = $0.1 { true } else { false } }
        XCTAssertEqual(warnings.map(\.0), [at(10, 20), at(10, 25), at(10, 28)])
        XCTAssertTrue(warnings.allSatisfy { $0.1 == .hardStopWarning(id: stop.id, startsAt: at(10, 30), waitingForCall: false) })
    }

    func testMissedHardStopWarningsAreNotReplayed() throws {
        let stop = hardStop(warnings: [10, 5, 2])
        var scheduler = makeScheduler(stops: [stop])
        let warning = BreakScheduler.Event.hardStopWarning(id: stop.id, startsAt: at(10, 30), waitingForCall: false)
        XCTAssertEqual(scheduler.tick(now: at(10, 21)), [warning])
        // Asleep from 10:21 to 10:29: the 5-minute warning is skipped, and only the latest (2 minutes) is shown.
        XCTAssertEqual(scheduler.tick(now: at(10, 29)), [warning])
        XCTAssertEqual(scheduler.snapshot.hardStopWarnings[stop.id.uuidString]?.minutes, 2)
        // A relaunch does not show it again.
        var restored = try relaunch(scheduler, at: at(10, 29, 10))
        XCTAssertTrue(restored.tick(now: at(10, 29, 20)).isEmpty)

        // Waking after the start shows no warning at all.
        var late = makeScheduler(stops: [stop])
        XCTAssertEqual(late.tick(now: at(10, 31)), [.hardStopStarted(id: stop.id, endsAt: at(11, 0))])
    }

    func testHardStopStartsAndEndsForEachEndType() {
        let after = hardStop(end: .after(30 * 60))
        var scheduler = makeScheduler(stops: [after])
        let events = runTimed(&scheduler, from: t0, through: at(11, 1)).filter { isHardStopEvent($0.1) }
        XCTAssertEqual(events.map(\.0), [at(10, 30), at(11, 0)])
        XCTAssertEqual(events.map(\.1), [.hardStopStarted(id: after.id, endsAt: at(11, 0)), .hardStopEnded(id: after.id, reason: .ended)])
        XCTAssertEqual(scheduler.phase, .focusing)

        let fixedEnd = hardStop(end: .at(hour: 10, minute: 45))
        var fixed = makeScheduler(stops: [fixedEnd])
        XCTAssertEqual(fixed.tick(now: at(10, 30)), [.hardStopStarted(id: fixedEnd.id, endsAt: at(10, 45))])
        XCTAssertEqual(fixed.snapshot.activeKind, .hardStop)
        XCTAssertEqual(fixed.breakRemaining(now: at(10, 40)), 5 * 60)
        XCTAssertEqual(fixed.tick(now: at(10, 45)), [.hardStopEnded(id: fixedEnd.id, reason: .ended)])

        let open = hardStop(end: .untilDismissed)
        var untilDismissed = makeScheduler(stops: [open])
        XCTAssertEqual(untilDismissed.tick(now: at(10, 30)), [.hardStopStarted(id: open.id, endsAt: nil)])
        XCTAssertTrue(runTimed(&untilDismissed, from: at(10, 30), through: at(20, 0), step: 60).isEmpty)
        XCTAssertEqual(untilDismissed.phase, .breaking)
        XCTAssertEqual(untilDismissed.dismissHardStop(now: at(20, 0)), [.hardStopEnded(id: open.id, reason: .dismissed)])
    }

    func testHardStopCrossingMidnightBelongsToItsStartWeekday() {
        // Monday only, 23:00 to 01:00.
        let stop = hardStop(hour: 23, minute: 0, end: .at(hour: 1, minute: 0), repeats: .weekdays([2]))
        var scheduler = makeScheduler(stops: [stop])
        XCTAssertEqual(scheduler.tick(now: at(23, 0)), [.hardStopStarted(id: stop.id, endsAt: at(1, 0, dayOffset: 1))])
        XCTAssertTrue(scheduler.tick(now: at(0, 30, dayOffset: 1)).isEmpty)
        XCTAssertEqual(scheduler.phase, .breaking)
        XCTAssertEqual(scheduler.tick(now: at(1, 0, dayOffset: 1)), [.hardStopEnded(id: stop.id, reason: .ended)])

        // A host that wakes at 00:30 on Tuesday joins Monday's occurrence.
        var woke = makeScheduler(stops: [stop])
        XCTAssertEqual(woke.tick(now: at(0, 30, dayOffset: 1)), [.hardStopStarted(id: stop.id, endsAt: at(1, 0, dayOffset: 1))])
        // 00:30 on Monday belongs to Sunday's occurrence, which is not selected.
        var early = makeScheduler(stops: [stop])
        XCTAssertTrue(early.tick(now: at(0, 30)).isEmpty)
    }

    func testOneOffHardStopRunsOnceAndIsRemoved() {
        let once = hardStop(hour: 10, minute: 5, end: .after(5 * 60), repeats: .once(on: t0, calendar: calendar))
        let weekly = hardStop(hour: 18, minute: 0)
        var scheduler = makeScheduler(stops: [once, weekly])
        let events = runTimed(&scheduler, from: t0, through: at(10, 11)).map(\.1).filter(isHardStopEvent)
        XCTAssertEqual(events, [.hardStopStarted(id: once.id, endsAt: at(10, 10)), .hardStopEnded(id: once.id, reason: .ended)])
        XCTAssertEqual(scheduler.settings.hardStops.map(\.id), [weekly.id])

        // At launch, a one-off stop whose date has passed is removed; a future one is kept.
        let yesterday = hardStop(repeats: .once(on: t0.addingTimeInterval(-24 * 3600), calendar: calendar))
        let tomorrow = hardStop(repeats: .once(on: t0.addingTimeInterval(24 * 3600), calendar: calendar))
        var launched = makeScheduler(stops: [yesterday, tomorrow])
        launched.reconcileRestoredState(now: t0)
        XCTAssertEqual(launched.settings.hardStops.map(\.id), [tomorrow.id])
    }

    func testRelaunchPartwayThroughHardStopKeepsItAndItsExtensions() throws {
        let stop = hardStop(escapeHatch: .extend(minutes: 5, times: 1))
        var scheduler = makeScheduler(stops: [stop])
        _ = scheduler.tick(now: at(10, 30))

        // Relaunched while shown: the stop is not ended as an ordinary break, and does not start again.
        var shown = try relaunch(scheduler, at: at(10, 31))
        XCTAssertFalse(shown.reconcileRestoredState(now: at(10, 31)), "A hard stop is not reported as a restored regular break")
        XCTAssertEqual(shown.phase, .breaking)
        XCTAssertTrue(shown.records.isEmpty)
        XCTAssertTrue(shown.tick(now: at(10, 31, 1)).isEmpty)
        XCTAssertEqual(shown.snapshot.breakEndsAt, at(11, 0))

        // Relaunched while hidden by an extension: it comes back on time, and the extension stays used.
        XCTAssertEqual(scheduler.extendHardStop(now: at(10, 31)), [.hardStopExtended(id: stop.id, until: at(10, 36))])
        var hidden = try relaunch(scheduler, at: at(10, 33))
        XCTAssertEqual(hidden.phase, .focusing)
        XCTAssertTrue(runTimed(&hidden, from: at(10, 33), through: at(10, 35, 59)).isEmpty)
        XCTAssertEqual(hidden.tick(now: at(10, 36)), [.hardStopResumed(id: stop.id)])
        XCTAssertFalse(hidden.canExtendHardStop(now: at(10, 37)))
        XCTAssertTrue(hidden.extendHardStop(now: at(10, 37)).isEmpty)
    }

    func testRelaunchOrWakeAfterHardStopEndedRecordsItsScheduledEnd() throws {
        let stop = hardStop()
        var scheduler = makeScheduler(stops: [stop])
        _ = scheduler.tick(now: at(10, 30))

        var restored = try relaunch(scheduler, at: at(12, 0))
        XCTAssertEqual(restored.tick(now: at(12, 0)), [.hardStopEnded(id: stop.id, reason: .ended)])
        XCTAssertEqual(restored.records.last?.endedAt, at(11, 0))
        XCTAssertEqual(restored.phase, .focusing)
        XCTAssertEqual(restored.snapshot.nextBreakAt, at(12, 0).addingTimeInterval(120 * 60))
        XCTAssertTrue(restored.tick(now: at(12, 0, 1)).isEmpty)

        // Waking partway through an occurrence that started while asleep joins it for the time left.
        var woke = makeScheduler(stops: [stop])
        XCTAssertEqual(woke.tick(now: at(10, 40)), [.hardStopStarted(id: stop.id, endsAt: at(11, 0))])
        _ = woke.tick(now: at(11, 0))
        XCTAssertEqual(woke.records.last?.startedAt, at(10, 40))
    }

    func testHardStopOverridesPausesIdleAndOfficeHours() {
        struct Case {
            var name: String
            var configure: (inout BreakSettings) -> Void = { _ in }
            var prepare: (inout BreakScheduler, Date) -> Void = { _, _ in }
            var inputs = BreakScheduler.Inputs()
            /// A manual pause does not come back after the stop; an automatic one follows its live signal again.
            var freshFocusAfter = true
            /// The reason reminders are paused just before the stop, or nil when they are held by office hours.
            var pausedBy: PauseReason?
        }
        let cases = [
            Case(name: "manual pause", prepare: { s, now in _ = s.pause(now: now) }, pausedBy: .manual),
            Case(name: "timed manual pause", prepare: { s, now in _ = s.pause(until: now.addingTimeInterval(4 * 3600), now: now) }, pausedBy: .manual),
            Case(name: "media", inputs: .init(signals: [.media]), freshFocusAfter: false, pausedBy: .media),
            Case(name: "chosen app", configure: { $0.smartPause.deepFocusApps = true }, inputs: .init(signals: [.app]), freshFocusAfter: false, pausedBy: .app),
            Case(name: "game", configure: { $0.smartPause.games = true }, inputs: .init(signals: [.game]), freshFocusAfter: false, pausedBy: .game),
            Case(name: "idle pause", inputs: .init(idleSeconds: 120), freshFocusAfter: false, pausedBy: .idle),
            Case(name: "idle reset", inputs: .init(idleSeconds: 10 * 60), freshFocusAfter: false, pausedBy: .idle),
            Case(name: "office hours", configure: {
                $0.officeHours = OfficeHours(isEnabled: true, startHour: 12, startMinute: 0, endHour: 18, endMinute: 0, weekdays: [2])
            })
        ]
        for testCase in cases {
            let stop = hardStop()
            var scheduler = makeScheduler(stops: [stop], testCase.configure)
            testCase.prepare(&scheduler, at(10, 29))
            _ = scheduler.tick(now: at(10, 29), inputs: testCase.inputs)
            if let reason = testCase.pausedBy {
                XCTAssertEqual(scheduler.pauseReasonForTest, reason, testCase.name)
            } else {
                XCTAssertFalse(scheduler.settings.officeHours.contains(at(10, 29), calendar: calendar), testCase.name)
            }
            XCTAssertEqual(scheduler.tick(now: at(10, 30), inputs: testCase.inputs), [.hardStopStarted(id: stop.id, endsAt: at(11, 0))], testCase.name)
            XCTAssertEqual(scheduler.snapshot.activeKind, .hardStop, testCase.name)
            XCTAssertNil(scheduler.pauseReasonForTest, testCase.name)
            XCTAssertTrue(runTimed(&scheduler, from: at(10, 30), through: at(10, 59, 59), inputs: { _ in testCase.inputs }).isEmpty, testCase.name)
            let ended = scheduler.tick(now: at(11, 0), inputs: testCase.inputs)
            XCTAssertEqual(ended.first, .hardStopEnded(id: stop.id, reason: .ended), testCase.name)
            if testCase.freshFocusAfter {
                XCTAssertEqual(scheduler.phase, .focusing, testCase.name)
                XCTAssertEqual(scheduler.snapshot.nextBreakAt, at(11, 0).addingTimeInterval(120 * 60), testCase.name)
            }
        }
    }

    func testHardStopEndsRunningBreaksAndHoldsTheSchedule() {
        let stop = hardStop()

        // A running regular break ends and counts as completed.
        var regular = makeScheduler(stops: [stop]) { $0.shortBreakDuration = 120 }
        _ = regular.startBreak(kind: .short, now: at(10, 29))
        XCTAssertEqual(regular.tick(now: at(10, 30)), [.breakEnded(completed: true), .hardStopStarted(id: stop.id, endsAt: at(11, 0))])
        XCTAssertEqual(regular.records.first?.kind, .short)
        XCTAssertEqual(regular.records.first?.completed, true)
        XCTAssertEqual(regular.records.first?.endedAt, at(10, 30))

        // So does a running planned break.
        let walk = PlannedBreak(name: "Walk", symbol: "figure.walk", hour: 10, minute: 20, duration: 20 * 60, weekdays: [2], isEnabled: true)
        var planned = makeScheduler(stops: [stop]) { $0.plannedBreaks = [walk] }
        _ = planned.tick(now: at(10, 20))
        XCTAssertEqual(planned.tick(now: at(10, 30)), [.breakEnded(completed: true), .hardStopStarted(id: stop.id, endsAt: at(11, 0))])
        XCTAssertEqual(planned.records.first?.kind, .planned)
        XCTAssertEqual(planned.records.first?.completed, true)

        // A shown heads-up is withdrawn. During the stop no break, heads-up, or nudge starts, and a planned
        // break due inside it does not start after it either.
        let later = PlannedBreak(name: "Walk", symbol: "figure.walk", hour: 10, minute: 50, duration: 20 * 60, weekdays: [2], isEnabled: true)
        var held = makeScheduler(stops: [stop]) {
            $0.workInterval = 30 * 60 + 30
            $0.plannedBreaks = [later]
            $0.wellness.blinkEnabled = true
            $0.wellness.blinkInterval = 60
        }
        _ = held.tick(now: at(10, 29, 40))
        XCTAssertEqual(held.phase, .headsUp)
        XCTAssertEqual(held.tick(now: at(10, 30)), [.headsUpCancelled, .hardStopStarted(id: stop.id, endsAt: at(11, 0))])
        XCTAssertTrue(runTimed(&held, from: at(10, 30), through: at(10, 59, 59)).isEmpty)
        XCTAssertEqual(held.tick(now: at(11, 0)), [.hardStopEnded(id: stop.id, reason: .ended)])
        XCTAssertFalse(runTimed(&held, from: at(11, 0), through: at(11, 10)).contains { if case .breakStarted = $0.1 { true } else { false } })
    }

    func testHardStopWaitsForCallsStartsLateOrIsMissed() {
        let stop = hardStop(warnings: [2])
        let call: (Date) -> BreakScheduler.Inputs = { _ in .init(signals: [.meeting]) }

        // The call ends at 10:40: the stop starts on that tick, and its end does not move.
        var waits = makeScheduler(stops: [stop])
        let during = runTimed(&waits, from: at(10, 27), through: at(10, 39, 59), inputs: call).map(\.1).filter(isHardStopEvent)
        XCTAssertEqual(during, [.hardStopWarning(id: stop.id, startsAt: at(10, 30), waitingForCall: true)])
        XCTAssertEqual(waits.tick(now: at(10, 40)), [.hardStopStarted(id: stop.id, endsAt: at(11, 0))])

        // The meeting signal counts as a call even when it does not pause reminders.
        var unpaused = makeScheduler(stops: [stop]) { $0.smartPause.meetingsAndCalls = false }
        XCTAssertTrue(unpaused.tick(now: at(10, 30), inputs: .init(signals: [.meeting])).isEmpty)

        var anyway = makeScheduler(stops: [hardStop(duringCalls: .startAnyway)])
        XCTAssertEqual(anyway.tick(now: at(10, 30), inputs: .init(signals: [.meeting])).count, 1)
        XCTAssertEqual(anyway.snapshot.activeKind, .hardStop)

        // The call outlasts the stop: it ends as missed, is recorded, and never starts.
        var missed = makeScheduler(stops: [stop])
        let events = runTimed(&missed, from: at(10, 29), through: at(11, 0), inputs: call).map(\.1).filter(isHardStopEvent)
        XCTAssertEqual(events, [
            .hardStopWarning(id: stop.id, startsAt: at(10, 30), waitingForCall: true),
            .hardStopEnded(id: stop.id, reason: .missed)
        ])
        XCTAssertEqual(missed.records.last?.hardStopEndReason, .missed)
        XCTAssertEqual(missed.records.last?.startedAt, at(10, 30))
        XCTAssertEqual(missed.records.last?.endedAt, at(11, 0))
        XCTAssertTrue(runTimed(&missed, from: at(11, 0), through: at(11, 5)).filter { isHardStopEvent($0.1) }.isEmpty)

        // A one-off stop is removed after it is missed.
        var missedOnce = makeScheduler(stops: [hardStop(repeats: .once(on: t0, calendar: calendar))])
        _ = runTimed(&missedOnce, from: at(10, 29), through: at(11, 0), step: 30, inputs: call)
        XCTAssertEqual(missedOnce.records.last?.hardStopEndReason, .missed)
        XCTAssertTrue(missedOnce.settings.hardStops.isEmpty)

        // A stop without an end always waits.
        let open = hardStop(end: .untilDismissed)
        var always = makeScheduler(stops: [open])
        XCTAssertTrue(runTimed(&always, from: at(10, 29), through: at(18, 0), step: 60, inputs: call).filter { isHardStopEvent($0.1) }.isEmpty)
        XCTAssertEqual(always.tick(now: at(18, 0, 1)), [.hardStopStarted(id: open.id, endsAt: nil)])
    }

    func testWaitingOccurrencesSurviveDaysAndAreMissedBeforeTheNextOne() {
        let call: (Date) -> BreakScheduler.Inputs = { _ in .init(signals: [.meeting]) }
        // A Monday stop without an end waits through a call that lasts until Wednesday, and is kept meanwhile.
        let open = hardStop(end: .untilDismissed, repeats: .once(on: t0, calendar: calendar))
        var waits = makeScheduler(stops: [open])
        let during = runTimed(&waits, from: at(10, 29), through: at(9, 0, dayOffset: 2), step: 600, inputs: call)
        XCTAssertTrue(during.filter { isHardStopEvent($0.1) }.isEmpty)
        XCTAssertEqual(waits.settings.hardStops.map(\.id), [open.id])
        XCTAssertEqual(waits.tick(now: at(9, 0, 1, dayOffset: 2)), [.hardStopStarted(id: open.id, endsAt: nil)])

        // A daily stop that waited on Monday is recorded as missed before Tuesday's occurrence starts waiting.
        let daily = hardStop(repeats: .weekdays([2, 3]))
        var missed = makeScheduler(stops: [daily])
        XCTAssertTrue(missed.tick(now: at(10, 30), inputs: .init(signals: [.meeting])).filter(isHardStopEvent).isEmpty)
        XCTAssertEqual(missed.tick(now: at(10, 30, dayOffset: 1), inputs: .init(signals: [.meeting])).filter(isHardStopEvent),
                       [.hardStopEnded(id: daily.id, reason: .missed)])
        XCTAssertEqual(missed.records.map(\.startedAt), [at(10, 30)])
        XCTAssertEqual(missed.tick(now: at(10, 31, dayOffset: 1)), [.hardStopStarted(id: daily.id, endsAt: at(11, 0, dayOffset: 1))])
    }

    func testEarlierOpenOccurrenceIsKeptWhenTheNextOneArrives() throws {
        let stop = hardStop(end: .untilDismissed, repeats: .weekdays([2, 3]), escapeHatch: .none)
        let call = BreakScheduler.Inputs(signals: [.meeting])

        // A call from Monday 10:30 past Tuesday 10:30, with a relaunch: Monday's occurrence starts when the call
        // ends, and Tuesday's joins it. Both are recorded.
        var waiting = makeScheduler(stops: [stop])
        _ = waiting.tick(now: at(10, 30), inputs: call)
        _ = waiting.tick(now: at(10, 30, dayOffset: 1), inputs: call)
        var restored = try relaunch(waiting, at: at(10, 35, dayOffset: 1))
        XCTAssertEqual(restored.tick(now: at(10, 40, dayOffset: 1)), [.hardStopStarted(id: stop.id, endsAt: nil)])
        XCTAssertEqual(restored.snapshot.activeHardStop?.occurrence, at(10, 30))
        XCTAssertEqual(restored.dismissHardStop(now: at(11, 0, dayOffset: 1)), [.hardStopEnded(id: stop.id, reason: .dismissed)])
        XCTAssertEqual(restored.records.count, 2)
        XCTAssertTrue(restored.tick(now: at(11, 0, 1, dayOffset: 1)).isEmpty)

        // A host that was off from Monday morning until Tuesday 10:35 does the same.
        var off = makeScheduler(stops: [stop])
        XCTAssertEqual(off.tick(now: at(10, 35, dayOffset: 1)), [.hardStopStarted(id: stop.id, endsAt: nil)])
        XCTAssertEqual(off.snapshot.activeHardStop?.occurrence, at(10, 30))
        _ = off.dismissHardStop(now: at(11, 0, dayOffset: 1))
        XCTAssertEqual(off.records.count, 2)
    }

    func testOneOffStopRescheduledWhileRunningKeepsItsNewDate() {
        let once = hardStop(repeats: .once(on: t0, calendar: calendar))
        var scheduler = makeScheduler(stops: [once])
        _ = scheduler.tick(now: at(10, 30))
        scheduler.settings.hardStops[0].repeats = .once(on: t0.addingTimeInterval(24 * 3600), calendar: calendar)
        XCTAssertEqual(scheduler.tick(now: at(11, 0)), [.hardStopEnded(id: once.id, reason: .ended)])
        XCTAssertEqual(scheduler.settings.hardStops.map(\.id), [once.id])
        XCTAssertEqual(scheduler.tick(now: at(10, 30, dayOffset: 1)), [.hardStopStarted(id: once.id, endsAt: at(11, 0, dayOffset: 1))])
    }

    func testLaterOccurrenceDoesNotConsumeAnEarlierOneWaitingForCall() {
        let call = BreakScheduler.Inputs(signals: [.meeting])
        let b = hardStop(hour: 10, minute: 0, end: .after(2 * 3600), repeats: .weekdays([3]), escapeHatch: .dismissEarly, duringCalls: .startAnyway)

        // S runs 24 hours from 10:30. Monday's occurrence waits through a call that lasts past Tuesday 10:30, when
        // Tuesday's occurrence starts inside B: Monday's is recorded as missed first.
        let s = hardStop(end: .at(hour: 10, minute: 30), repeats: .weekdays([2, 3]))
        var bounded = makeScheduler(stops: [s, b])
        _ = bounded.tick(now: at(10, 30), inputs: call)
        XCTAssertEqual(bounded.tick(now: at(10, 0, dayOffset: 1), inputs: call), [.hardStopStarted(id: b.id, endsAt: at(12, 0, dayOffset: 1))])
        XCTAssertEqual(bounded.tick(now: at(10, 30, dayOffset: 1), inputs: call), [.hardStopEnded(id: s.id, reason: .missed)])
        XCTAssertEqual(bounded.records.map(\.startedAt), [at(10, 30)])
        XCTAssertEqual(bounded.snapshot.activeHardStop?.merged.map(\.id), [s.id])

        // Without an end, Monday's occurrence keeps waiting; when the call ends it joins B, and Tuesday's follows.
        let open = hardStop(end: .untilDismissed, repeats: .weekdays([2, 3]))
        var waiting = makeScheduler(stops: [open, b])
        _ = waiting.tick(now: at(10, 30), inputs: call)
        _ = waiting.tick(now: at(10, 0, dayOffset: 1), inputs: call)
        XCTAssertTrue(waiting.tick(now: at(10, 30, dayOffset: 1), inputs: call).isEmpty)
        XCTAssertEqual(waiting.snapshot.activeHardStop?.merged, [])
        XCTAssertTrue(waiting.tick(now: at(10, 40, dayOffset: 1)).isEmpty)
        XCTAssertTrue(waiting.tick(now: at(10, 40, 1, dayOffset: 1)).isEmpty)
        XCTAssertNil(waiting.snapshot.breakEndsAt)
        XCTAssertEqual(waiting.dismissHardStop(now: at(10, 41, dayOffset: 1)), [.hardStopEnded(id: b.id, reason: .dismissed)])
        XCTAssertEqual(waiting.records.count, 3, "B, and Monday's and Tuesday's occurrences of the open stop")
    }

    func testStopWaitingForCallMergesIntoRunningStop() {
        // A is running when a call starts; B starts inside A and would wait for the call, but joins A instead.
        let a = hardStop(hour: 10, minute: 0, end: .after(60 * 60))
        let b = hardStop(hour: 10, minute: 30, end: .at(hour: 12, minute: 0), repeats: .once(on: t0, calendar: calendar), escapeHatch: .dismissEarly)
        var scheduler = makeScheduler(stops: [a, b])
        _ = scheduler.tick(now: at(10, 0))
        let events = runTimed(&scheduler, from: at(10, 20), through: at(11, 30), step: 10) { _ in .init(signals: [.meeting]) }
        XCTAssertTrue(events.filter { isHardStopEvent($0.1) }.isEmpty)
        XCTAssertEqual(scheduler.snapshot.breakEndsAt, at(12, 0))
        XCTAssertTrue(scheduler.canDismissHardStop(now: at(11, 30)))
        XCTAssertEqual(scheduler.settings.hardStops.count, 2, "A merged one-off stop is removed when the running stop ends")
        XCTAssertEqual(scheduler.tick(now: at(12, 0), inputs: .init(signals: [.meeting])).first, .hardStopEnded(id: a.id, reason: .ended))
        XCTAssertEqual(scheduler.settings.hardStops.map(\.id), [a.id])
        XCTAssertEqual(scheduler.records.map(\.hardStopEndReason), [.ended, .ended])
        XCTAssertEqual(scheduler.records.map(\.startedAt), [at(10, 0), at(10, 30)])
    }

    func testStopWhoseCallEndsWhileAnotherRunsJoinsIt() {
        // A waits for the call; B starts anyway at 10:30. The call ends at 10:40 while B runs: A joins B then and
        // is recorded, instead of being missed at 11:00.
        let a = hardStop(hour: 10, minute: 0, end: .after(60 * 60))
        let b = hardStop(hour: 10, minute: 30, end: .at(hour: 12, minute: 0), duringCalls: .startAnyway)
        var scheduler = makeScheduler(stops: [a, b])
        let call = BreakScheduler.Inputs(signals: [.meeting])
        _ = scheduler.tick(now: at(10, 0), inputs: call)
        XCTAssertEqual(scheduler.tick(now: at(10, 30), inputs: call), [.hardStopStarted(id: b.id, endsAt: at(12, 0))])
        XCTAssertTrue(scheduler.tick(now: at(10, 40)).isEmpty)
        XCTAssertEqual(runTimed(&scheduler, from: at(10, 40), through: at(12, 0), step: 30).map(\.1), [.hardStopEnded(id: b.id, reason: .ended)])
        XCTAssertEqual(scheduler.records.map(\.startedAt), [at(10, 30), at(10, 40)])
        XCTAssertEqual(scheduler.records.map(\.endedAt), [at(12, 0), at(11, 0)])
        XCTAssertEqual(scheduler.records.map(\.hardStopEndReason), [.ended, .ended])
    }

    func testMergeWhileHiddenMovesTheHiddenCountdown() {
        let a = hardStop(escapeHatch: .extend(minutes: 30, times: 1))
        let b = hardStop(hour: 10, minute: 55, end: .at(hour: 12, minute: 0))
        var scheduler = makeScheduler(stops: [a, b])
        _ = scheduler.tick(now: at(10, 30))
        _ = scheduler.extendHardStop(now: at(10, 50))
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, at(11, 0))
        XCTAssertTrue(scheduler.tick(now: at(10, 55)).isEmpty)
        XCTAssertEqual(scheduler.nextBreakRemaining(now: at(11, 5)), 15 * 60)
        XCTAssertTrue(runTimed(&scheduler, from: at(10, 55), through: at(11, 19, 59), step: 30).isEmpty)
        XCTAssertEqual(scheduler.tick(now: at(11, 20)), [.hardStopResumed(id: a.id)])
        XCTAssertEqual(scheduler.snapshot.breakEndsAt, at(12, 0))
    }

    func testMissedTicksGiveTheSameOverlapAndPlannedBreakOutcome() {
        // A 10:30–11:00, B 10:45–11:10, C 11:05–11:30: B extends A, so C starts inside it too.
        let a = hardStop()
        let b = hardStop(hour: 10, minute: 45, end: .at(hour: 11, minute: 10))
        let c = hardStop(hour: 11, minute: 5, end: .at(hour: 11, minute: 30))
        var asleep = makeScheduler(stops: [a, b, c])
        _ = asleep.tick(now: at(10, 30))
        XCTAssertTrue(asleep.tick(now: at(11, 20)).isEmpty)
        XCTAssertEqual(asleep.snapshot.activeHardStop?.id, a.id)
        XCTAssertEqual(asleep.snapshot.breakEndsAt, at(11, 30))
        XCTAssertEqual(asleep.tick(now: at(11, 30)), [.hardStopEnded(id: a.id, reason: .ended)])

        // A planned break inside the stop is dropped even when no tick ran while it was due.
        let walk = PlannedBreak(name: "Walk", symbol: "figure.walk", hour: 10, minute: 50, duration: 20 * 60, weekdays: [2], isEnabled: true)
        var planned = makeScheduler(stops: [a]) { $0.plannedBreaks = [walk] }
        _ = planned.tick(now: at(10, 30))
        XCTAssertEqual(planned.tick(now: at(11, 5)), [.hardStopEnded(id: a.id, reason: .ended)])
        XCTAssertEqual(planned.phase, .focusing)
        // One that starts after a dismissed stop still runs.
        var dismissed = makeScheduler(stops: [hardStop(escapeHatch: .dismissEarly)]) { $0.plannedBreaks = [walk] }
        _ = dismissed.tick(now: at(10, 30))
        _ = dismissed.dismissHardStop(now: at(10, 40))
        XCTAssertEqual(dismissed.tick(now: at(10, 50)), [.breakStarted(.planned, duration: 20 * 60)])
    }

    func testStopWaitingForCallHoldsTheRegularSchedule() {
        // The meeting does not pause reminders here, so only the waiting stop holds the break due at 10:30.
        let stop = hardStop()
        let walk = PlannedBreak(name: "Walk", symbol: "figure.walk", hour: 10, minute: 35, duration: 10 * 60, weekdays: [2], isEnabled: true)
        var scheduler = makeScheduler(stops: [stop]) {
            $0.workInterval = 30 * 60
            $0.smartPause.meetingsAndCalls = false
            $0.plannedBreaks = [walk]
        }
        let call = BreakScheduler.Inputs(idleSeconds: 10 * 60, signals: [.meeting])
        XCTAssertEqual(scheduler.tick(now: at(10, 29, 30)), [.headsUp(breakAt: at(10, 30))])
        XCTAssertEqual(scheduler.tick(now: at(10, 30), inputs: call), [.headsUpCancelled])
        XCTAssertTrue(runTimed(&scheduler, from: at(10, 30), through: at(10, 39, 59), inputs: { _ in call }).isEmpty)
        XCTAssertTrue(scheduler.pause(now: at(10, 39)).isEmpty)
        XCTAssertTrue(scheduler.startBreak(now: at(10, 39)).isEmpty)
        XCTAssertEqual(scheduler.phase, .focusing)
        XCTAssertEqual(scheduler.tick(now: at(10, 40)), [.hardStopStarted(id: stop.id, endsAt: at(11, 0))])

        // When the call outlasts the stop, the held schedule restarts with a fresh focus interval.
        var missed = makeScheduler(stops: [stop]) {
            $0.workInterval = 30 * 60
            $0.smartPause.meetingsAndCalls = false
        }
        _ = runTimed(&missed, from: at(10, 29), through: at(10, 59, 59), step: 30, inputs: { _ in .init(signals: [.meeting]) })
        XCTAssertEqual(missed.tick(now: at(11, 0), inputs: .init(signals: [.meeting])), [.hardStopEnded(id: stop.id, reason: .missed)])
        XCTAssertEqual(missed.snapshot.nextBreakAt, at(11, 30))
    }

    func testMissedStopDiscardsAPauseFromBeforeIt() {
        // A manual pause from 10:29 is held while the stop waits for the call. When the stop is missed at 11:00, a
        // fresh focus interval starts instead of the pause coming back; the live call may then pause that interval.
        let stop = hardStop()
        let call = BreakScheduler.Inputs(signals: [.meeting])
        var indefinite = makeScheduler(stops: [stop])
        XCTAssertEqual(indefinite.pause(now: at(10, 29)), [.paused(.manual)])
        XCTAssertTrue(indefinite.tick(now: at(10, 30), inputs: call).isEmpty)
        XCTAssertEqual(indefinite.tick(now: at(11, 0), inputs: call), [.hardStopEnded(id: stop.id, reason: .missed), .paused(.meeting)])
        XCTAssertEqual(indefinite.snapshot.pauseReason, .meeting)
        XCTAssertEqual(indefinite.snapshot.pausedRemaining, 120 * 60)

        // A timed pause whose time ran out while the stop waited does not bring back its old remaining interval.
        var timed = makeScheduler(stops: [stop])
        XCTAssertEqual(timed.pause(until: at(10, 45), now: at(10, 29)), [.paused(.manual)])
        XCTAssertTrue(timed.tick(now: at(10, 30), inputs: call).isEmpty)
        XCTAssertEqual(timed.tick(now: at(11, 0)), [.hardStopEnded(id: stop.id, reason: .missed)])
        XCTAssertEqual(timed.phase, .focusing)
        XCTAssertEqual(timed.snapshot.nextBreakAt, at(13, 0))
    }

    func testMissedStopKeepsTheFocusStretchAndDropsAHeldPlannedBreak() {
        // Focus since 10:00. The stop waits for the call from 10:30 and is missed at 11:00, holding the planned
        // break due at 10:40. The planned break does not start afterwards, and the hour of focus still counts.
        let stop = hardStop()
        let walk = PlannedBreak(name: "Walk", symbol: "figure.walk", hour: 10, minute: 40, duration: 30 * 60, weekdays: [2], isEnabled: true)
        var scheduler = makeScheduler(stops: [stop]) {
            $0.plannedBreaks = [walk]
            $0.smartPause.meetingsAndCalls = false
        }
        _ = runTimed(&scheduler, from: at(10, 29), through: at(10, 59, 30), step: 30, inputs: { _ in .init(signals: [.meeting]) })
        XCTAssertEqual(scheduler.tick(now: at(11, 0)), [.hardStopEnded(id: stop.id, reason: .missed)])
        XCTAssertTrue(runTimed(&scheduler, from: at(11, 0), through: at(11, 15), step: 30).isEmpty)
        let stats = scheduler.stats(now: at(11, 0))
        XCTAssertEqual(stats.focusTime, 60 * 60)
        XCTAssertEqual(stats.longestStretch, 60 * 60)
        XCTAssertEqual(stats.breaksTaken, 0)
    }

    func testStopThatStartedBeforeTheRunningOneDoesNotJoinIt() {
        // A runs 10:30–11:30. B, added at 10:59, ran from 10:00 to 13:00 and would let A be dismissed. It does not
        // change A; it starts when A ends.
        let a = hardStop(end: .after(60 * 60))
        let b = hardStop(hour: 10, minute: 0, end: .at(hour: 13, minute: 0), escapeHatch: .dismissEarly)
        var scheduler = makeScheduler(stops: [a])
        _ = scheduler.tick(now: at(10, 30))
        scheduler.settings.hardStops.append(b)
        XCTAssertTrue(scheduler.tick(now: at(11, 0)).isEmpty)
        XCTAssertEqual(scheduler.snapshot.breakEndsAt, at(11, 30))
        XCTAssertFalse(scheduler.canDismissHardStop(now: at(11, 1)))
        XCTAssertEqual(scheduler.tick(now: at(11, 30)), [.hardStopEnded(id: a.id, reason: .ended), .hardStopStarted(id: b.id, endsAt: at(13, 0))])
    }

    func testOperationBeforeTickMissesExpiredWaitLikeATick() {
        // S waits for Monday's call; B starts anyway inside it at 10:45 and lasts until dismissed. With no tick
        // until Tuesday 10:40, Monday's S is missed and Tuesday's S, which started inside B, joins B.
        let s = hardStop(repeats: .weekdays([2, 3]))
        let b = hardStop(hour: 10, minute: 45, end: .untilDismissed, duringCalls: .startAnyway)
        let call = BreakScheduler.Inputs(signals: [.meeting])
        var scheduler = makeScheduler(stops: [s, b])
        XCTAssertTrue(scheduler.tick(now: at(10, 30), inputs: call).isEmpty)
        XCTAssertEqual(scheduler.tick(now: at(10, 45), inputs: call), [.hardStopStarted(id: b.id, endsAt: nil)])
        let tuesday = at(10, 40, dayOffset: 1)

        // A refused operation changes nothing; the next tick reports the miss.
        var refused = scheduler
        XCTAssertTrue(refused.extendHardStop(now: tuesday).isEmpty)
        XCTAssertEqual(refused.snapshot, scheduler.snapshot)
        XCTAssertEqual(refused.tick(now: tuesday), [.hardStopEnded(id: s.id, reason: .missed)])

        var ticked = scheduler
        let tickedEvents = ticked.tick(now: tuesday) + ticked.dismissHardStop(now: tuesday)
        let events = scheduler.dismissHardStop(now: tuesday)
        XCTAssertEqual(events, [.hardStopEnded(id: s.id, reason: .missed), .hardStopEnded(id: b.id, reason: .dismissed)])
        XCTAssertEqual(events, tickedEvents)
        XCTAssertEqual(scheduler.records.map(\.hardStopEndReason), [.missed, .dismissed, .dismissed])
        XCTAssertEqual(scheduler.records.map(\.hardStopEndReason), ticked.records.map(\.hardStopEndReason))
        XCTAssertEqual(scheduler.records.map(\.startedAt), [at(10, 30), at(10, 45), at(10, 30, dayOffset: 1)])
        XCTAssertEqual(scheduler.records.map(\.startedAt), ticked.records.map(\.startedAt))
        XCTAssertEqual(scheduler.records.map(\.endedAt), ticked.records.map(\.endedAt))
        // Tuesday's S was dismissed with B, so it does not start again.
        XCTAssertTrue(runTimed(&scheduler, from: tuesday, through: at(11, 5, dayOffset: 1), step: 30).filter { isHardStopEvent($0.1) }.isEmpty)
    }

    func testOverlappingHardStopsMerge() {
        // B starts inside A and ends later: A runs until B's end with B's escape hatch, and B shows no warnings.
        let a = hardStop(escapeHatch: .extend(minutes: 15, times: 1))
        let b = hardStop(hour: 10, minute: 45, end: .at(hour: 11, minute: 30), warnings: [10, 5], escapeHatch: .dismissEarly)
        var scheduler = makeScheduler(stops: [a, b])
        let events = runTimed(&scheduler, from: t0, through: at(10, 44, 59)).map(\.1)
        XCTAssertEqual(events, [.hardStopStarted(id: a.id, endsAt: at(11, 0))])
        XCTAssertTrue(scheduler.tick(now: at(10, 45)).isEmpty)
        XCTAssertEqual(scheduler.snapshot.breakEndsAt, at(11, 30))
        XCTAssertTrue(scheduler.canDismissHardStop(now: at(10, 46)))
        XCTAssertFalse(scheduler.canExtendHardStop(now: at(10, 46)))
        XCTAssertEqual(runTimed(&scheduler, from: at(10, 45), through: at(11, 31)).map(\.1), [.hardStopEnded(id: a.id, reason: .ended)])
        // Each occurrence is recorded: A for the whole stop, and B from its own start to its own end.
        XCTAssertEqual(scheduler.records.map(\.startedAt), [at(10, 30), at(10, 45)])
        XCTAssertEqual(scheduler.records.map(\.endedAt), [at(11, 30), at(11, 30)])
        XCTAssertEqual(scheduler.records.map(\.extensionsUsed), [0, 0])

        // A stop that ends earlier keeps the running stop's end and escape hatch.
        let short = hardStop(hour: 10, minute: 45, end: .after(5 * 60), escapeHatch: .dismissEarly)
        var kept = makeScheduler(stops: [a, short])
        _ = kept.tick(now: at(10, 30))
        _ = kept.tick(now: at(10, 45))
        XCTAssertEqual(kept.snapshot.breakEndsAt, at(11, 0))
        XCTAssertFalse(kept.canDismissHardStop(now: at(10, 46)))
        XCTAssertTrue(kept.canExtendHardStop(now: at(10, 46)))
    }

    func testHardStopExtensionLimitAndResume() {
        let stop = hardStop(escapeHatch: .extend(minutes: 5, times: 2))
        var scheduler = makeScheduler(stops: [stop])
        _ = scheduler.tick(now: at(10, 30))
        XCTAssertEqual(scheduler.extendHardStop(now: at(10, 31)), [.hardStopExtended(id: stop.id, until: at(10, 36))])
        XCTAssertEqual(scheduler.phase, .focusing)
        XCTAssertTrue(scheduler.extendHardStop(now: at(10, 32)).isEmpty, "Already hidden")
        XCTAssertEqual(runTimed(&scheduler, from: at(10, 31), through: at(10, 36)).map(\.1), [.hardStopResumed(id: stop.id)])
        XCTAssertEqual(scheduler.phase, .breaking)
        XCTAssertEqual(scheduler.snapshot.breakEndsAt, at(11, 0), "Extending does not move the end")
        XCTAssertEqual(scheduler.extendHardStop(now: at(10, 37)), [.hardStopExtended(id: stop.id, until: at(10, 42))])
        XCTAssertEqual(scheduler.tick(now: at(10, 42)), [.hardStopResumed(id: stop.id)])
        XCTAssertTrue(scheduler.extendHardStop(now: at(10, 43)).isEmpty, "Both extensions are used")
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.extensionsUsed, 2)

        // When the end comes before the extension runs out, the stop ends instead of resuming.
        var pastEnd = makeScheduler(stops: [hardStop(escapeHatch: .extend(minutes: 15, times: 1))])
        let id = pastEnd.settings.hardStops[0].id
        _ = pastEnd.tick(now: at(10, 30))
        _ = pastEnd.extendHardStop(now: at(10, 50))
        XCTAssertEqual(runTimed(&pastEnd, from: at(10, 50), through: at(11, 10)).map(\.1), [.hardStopEnded(id: id, reason: .ended)])
        XCTAssertEqual(pastEnd.records.last?.extensionsUsed, 1)
    }

    func testHardStopDismissRulesForEachEscapeHatch() {
        func dismissed(_ escapeHatch: HardStop.EscapeHatch, end: HardStop.End = .after(30 * 60)) -> Bool {
            var scheduler = makeScheduler(stops: [hardStop(end: end, escapeHatch: escapeHatch)])
            _ = scheduler.tick(now: at(10, 30))
            return !scheduler.dismissHardStop(now: at(10, 35)).isEmpty
        }
        XCTAssertFalse(dismissed(.none))
        XCTAssertFalse(dismissed(.extend(minutes: 15, times: 1)))
        XCTAssertTrue(dismissed(.dismissEarly))
        XCTAssertTrue(dismissed(.none, end: .untilDismissed))
        XCTAssertTrue(dismissed(.extend(minutes: 15, times: 1), end: .untilDismissed))

        // Once the end has passed, the next tick ends the stop; dismissing it is not recorded instead.
        var overdue = makeScheduler(stops: [hardStop(escapeHatch: .dismissEarly)])
        _ = overdue.tick(now: at(10, 30))
        XCTAssertTrue(overdue.dismissHardStop(now: at(11, 0)).isEmpty)
        XCTAssertEqual(overdue.tick(now: at(11, 0)).first.map(isHardStopEvent), true)
        XCTAssertEqual(overdue.records.last?.hardStopEndReason, .ended)

        // A dismissed occurrence does not start again, and a fresh focus interval starts.
        let stop = hardStop(escapeHatch: .dismissEarly)
        var scheduler = makeScheduler(stops: [stop])
        _ = scheduler.tick(now: at(10, 30))
        XCTAssertEqual(scheduler.dismissHardStop(now: at(10, 35)), [.hardStopEnded(id: stop.id, reason: .dismissed)])
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, at(10, 35).addingTimeInterval(120 * 60))
        XCTAssertTrue(runTimed(&scheduler, from: at(10, 35), through: at(10, 40)).isEmpty)
        XCTAssertEqual(scheduler.records.last?.hardStopEndReason, .dismissed)
    }

    func testSnoozeSkipAndBreakOperationsHaveNoEffectDuringHardStop() {
        let stop = hardStop(escapeHatch: .extend(minutes: 5, times: 1))
        var scheduler = makeScheduler(stops: [stop]) { $0.discipline = .balanced }
        _ = scheduler.tick(now: at(10, 30))
        let now = at(10, 30, 2)
        XCTAssertFalse(scheduler.canSkipBreak(now: now))
        XCTAssertFalse(scheduler.canEndEarly(now: now))
        XCTAssertFalse(scheduler.canSnoozeActiveBreak(now: now))
        XCTAssertNil(scheduler.skipAvailableIn(now: now))
        XCTAssertTrue(scheduler.snooze(minutes: 5, now: now).isEmpty)
        XCTAssertTrue(scheduler.skipActiveBreak(now: now).isEmpty)
        XCTAssertTrue(scheduler.endBreak(completed: true, now: now).isEmpty)
        XCTAssertTrue(scheduler.pause(now: now).isEmpty)
        XCTAssertEqual(scheduler.snapshot.snoozesUsedToday, 0)
        XCTAssertEqual(scheduler.snapshot.activeKind, .hardStop)

        // Hidden by an extension, the stop is still running.
        _ = scheduler.extendHardStop(now: now)
        XCTAssertFalse(scheduler.canSkipUpcomingBreak)
        XCTAssertTrue(scheduler.snooze(minutes: 5, now: now).isEmpty)
        XCTAssertTrue(scheduler.skipUpcomingBreak(now: now).isEmpty)
        XCTAssertTrue(scheduler.startBreak(now: now).isEmpty)
        XCTAssertEqual(scheduler.snapshot.snoozesUsedToday, 0)
        XCTAssertTrue(scheduler.records.isEmpty)
    }

    func testHardStopHistoryRecordIsExcludedFromStatistics() {
        let stop = hardStop(escapeHatch: .extend(minutes: 5, times: 1))
        var scheduler = makeScheduler(stops: [stop])
        _ = scheduler.tick(now: at(10, 30))
        _ = scheduler.extendHardStop(now: at(10, 40))
        _ = scheduler.tick(now: at(10, 45))
        _ = scheduler.tick(now: at(11, 0))
        let record = scheduler.records.last
        XCTAssertEqual(record?.kind, .hardStop)
        XCTAssertEqual(record?.startedAt, at(10, 30))
        XCTAssertEqual(record?.endedAt, at(11, 0))
        XCTAssertEqual(record?.extensionsUsed, 1)
        XCTAssertEqual(record?.hardStopEndReason, .ended)

        let stats = scheduler.stats(now: at(11, 5))
        // The 30 minutes of focus before the stop still count, plus 5 minutes after it.
        XCTAssertEqual(stats.focusTime, 35 * 60)
        XCTAssertEqual(stats.longestStretch, 30 * 60)
        XCTAssertEqual(stats.breaksTaken, 0)
        XCTAssertEqual(stats.breakTime, 0)
        XCTAssertEqual(stats.skippedBreaks, 0)
        XCTAssertEqual(stats.screenScore, 100)
    }

    func testFocusStretchBeforeHardStopIsCountedOnce() {
        let stop = hardStop(escapeHatch: .extend(minutes: 15, times: 1))

        // While hidden by an extension and after resuming, the stats keep the 30-minute stretch before the stop
        // and leave out the hidden time.
        var extended = makeScheduler(stops: [stop])
        _ = extended.tick(now: at(10, 30))
        _ = extended.extendHardStop(now: at(10, 40))
        XCTAssertEqual(extended.stats(now: at(10, 50)).focusTime, 30 * 60)
        _ = extended.tick(now: at(10, 55))
        XCTAssertEqual(extended.stats(now: at(10, 57)).focusTime, 30 * 60)
        XCTAssertEqual(extended.stats(now: at(10, 57)).longestStretch, 30 * 60)

        // A stop that ends a running break adds no stretch: the break's record already holds the 29 minutes.
        var interrupted = makeScheduler(stops: [stop]) { $0.shortBreakDuration = 120 }
        _ = interrupted.startBreak(kind: .short, now: at(10, 29))
        _ = interrupted.tick(now: at(10, 30))
        _ = interrupted.tick(now: at(11, 0))
        XCTAssertEqual(interrupted.stats(now: at(11, 5)).focusTime, 34 * 60)
        XCTAssertEqual(interrupted.stats(now: at(11, 5)).longestStretch, 29 * 60)
        XCTAssertNil(interrupted.records.last?.focusDuration, "No zero-length stretch is added")

        // A stop that starts during an idle pause counts only the focus before the pause (4 minutes here).
        var idle = makeScheduler(stops: [stop])
        _ = idle.tick(now: at(10, 5), inputs: .init(idleSeconds: 60))
        XCTAssertEqual(idle.pauseReasonForTest, .idle)
        _ = idle.tick(now: at(10, 30), inputs: .init(idleSeconds: 25 * 60 + 60))
        _ = idle.tick(now: at(11, 0))
        XCTAssertEqual(idle.stats(now: at(11, 5)).focusTime, 9 * 60)
        XCTAssertEqual(idle.stats(now: at(11, 5)).longestStretch, 5 * 60)
    }

    func testEarlierStopWaitingForCallIsNotMergedIntoLaterOne() {
        // A waits for the call; B starts anyway inside A's window. A does not join B: it starts after the call.
        let a = hardStop(hour: 10, minute: 0, end: .after(60 * 60))
        let b = hardStop(hour: 10, minute: 30, end: .after(10 * 60), escapeHatch: .dismissEarly, duringCalls: .startAnyway)
        var scheduler = makeScheduler(stops: [a, b])
        let call = BreakScheduler.Inputs(signals: [.meeting])
        XCTAssertEqual(scheduler.tick(now: at(10, 30), inputs: call), [.hardStopStarted(id: b.id, endsAt: at(10, 40))])
        XCTAssertTrue(scheduler.canDismissHardStop(now: at(10, 31)))
        // After B, A still waits for the call and holds the regular schedule, so the meeting does not pause it.
        XCTAssertEqual(scheduler.tick(now: at(10, 40), inputs: call), [.hardStopEnded(id: b.id, reason: .ended)])
        XCTAssertEqual(scheduler.tick(now: at(10, 45)), [.hardStopStarted(id: a.id, endsAt: at(11, 0))])
    }

    func testStopWithoutEndThatStartedInsideRunningStopSurvivesMultiDayGap() throws {
        let a = hardStop()
        let b = hardStop(hour: 10, minute: 45, end: .untilDismissed, repeats: .once(on: t0, calendar: calendar))
        var scheduler = makeScheduler(stops: [a, b])
        _ = scheduler.tick(now: at(10, 30))

        // Relaunched on Wednesday: B is not removed before it merges, and A keeps running until dismissed.
        var restored = try relaunch(scheduler, at: at(12, 0, dayOffset: 2))
        XCTAssertEqual(restored.settings.hardStops.count, 2)
        XCTAssertTrue(restored.tick(now: at(12, 0, dayOffset: 2)).isEmpty)
        XCTAssertEqual(restored.snapshot.activeHardStop?.id, a.id)
        XCTAssertNil(restored.snapshot.breakEndsAt)
        XCTAssertTrue(restored.canDismissHardStop(now: at(12, 1, dayOffset: 2)))

        // The same without a relaunch, after the host slept until Wednesday.
        XCTAssertTrue(scheduler.tick(now: at(12, 0, dayOffset: 2)).isEmpty)
        XCTAssertNil(scheduler.snapshot.breakEndsAt)
        XCTAssertEqual(scheduler.dismissHardStop(now: at(12, 1, dayOffset: 2)), [.hardStopEnded(id: a.id, reason: .dismissed)])
        XCTAssertEqual(scheduler.settings.hardStops.map(\.id), [a.id])
    }

    func testTimeZoneChangeDuringStopDoesNotRunItsOccurrenceAgain() throws {
        // Both stops run 10:30–11:00 UTC. At 10:45 the time zone moves an hour west, so 10:30 local is now 11:30 UTC.
        let once = hardStop(repeats: .once(on: t0, calendar: calendar), warnings: [2])
        let weekly = hardStop(repeats: .weekdays([2]), warnings: [2])
        for stop in [once, weekly] {
            var scheduler = makeScheduler(stops: [stop])
            _ = scheduler.tick(now: at(10, 30))
            scheduler.calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -3600))
            XCTAssertEqual(scheduler.tick(now: at(11, 0)), [.hardStopEnded(id: stop.id, reason: .ended)])
            XCTAssertTrue(runTimed(&scheduler, from: at(11, 0), through: at(11, 40), step: 30).filter { isHardStopEvent($0.1) }.isEmpty)
            XCTAssertEqual(scheduler.records.count, 1)
        }
        // Whichever way the time zone moves, even across the date line, the one-off stop that ran is removed.
        for offset in [-3600, 12 * 3600] {
            var removed = makeScheduler(stops: [once])
            _ = removed.tick(now: at(10, 30))
            removed.calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: offset))
            _ = removed.tick(now: at(11, 0))
            XCTAssertTrue(removed.settings.hardStops.isEmpty, "The one-off stop ran, so it is removed")
            XCTAssertTrue(runTimed(&removed, from: at(11, 0), through: at(23, 30), step: 300).filter { isHardStopEvent($0.1) }.isEmpty)
        }
    }

    func testOccurrencesHeldBehindAWaitingOneJoinInOrderAfterIt() throws {
        // A waits for Monday's call until dismissed; B starts anyway inside it at 10:45. Tuesday's and Wednesday's A
        // start inside B but are held behind Monday's A. When the call ends on Wednesday, all three join B.
        let a = hardStop(end: .untilDismissed, repeats: .weekdays([2, 3, 4]))
        let b = hardStop(hour: 10, minute: 45, end: .untilDismissed, repeats: .once(on: t0, calendar: calendar), duringCalls: .startAnyway)
        let call = BreakScheduler.Inputs(signals: [.meeting])
        var scheduler = makeScheduler(stops: [a, b])
        XCTAssertTrue(scheduler.tick(now: at(10, 30), inputs: call).isEmpty)
        XCTAssertEqual(scheduler.tick(now: at(10, 45), inputs: call), [.hardStopStarted(id: b.id, endsAt: nil)])
        XCTAssertTrue(scheduler.tick(now: at(10, 40, dayOffset: 1), inputs: call).isEmpty)
        XCTAssertTrue(scheduler.tick(now: at(10, 40, dayOffset: 2), inputs: call).isEmpty)
        XCTAssertTrue(scheduler.tick(now: at(10, 40, 1, dayOffset: 2)).isEmpty)

        let restored = try relaunch(scheduler, at: at(10, 41, dayOffset: 2))
        for var host in [scheduler, restored] {
            XCTAssertEqual(host.dismissHardStop(now: at(10, 41, dayOffset: 2)), [.hardStopEnded(id: b.id, reason: .dismissed)])
            XCTAssertEqual(host.records.map(\.startedAt), [at(10, 45), at(10, 40, 1, dayOffset: 2), at(10, 30, dayOffset: 1), at(10, 30, dayOffset: 2)])
            XCTAssertEqual(Set(host.records.map(\.hardStopEndReason)), [.dismissed])
            XCTAssertTrue(runTimed(&host, from: at(10, 41, dayOffset: 2), through: at(11, 0, dayOffset: 2), step: 30).filter { isHardStopEvent($0.1) }.isEmpty)
        }
    }

    func testStopWaitingForCallStartsWhenTheCallEndsAfterATimeZoneChange() throws {
        // The stop waits for the call from 10:30 UTC. The time zone then moves an hour west, so 10:30 local is
        // 11:30 UTC. When the call ends at 10:40 UTC, the waiting occurrence starts and ends at its local end.
        let call = BreakScheduler.Inputs(signals: [.meeting])
        let timed = hardStop()
        var scheduler = makeScheduler(stops: [timed])
        XCTAssertTrue(scheduler.tick(now: at(10, 30), inputs: call).isEmpty)
        scheduler.calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -3600))
        XCTAssertEqual(scheduler.tick(now: at(10, 40)), [.hardStopStarted(id: timed.id, endsAt: at(12, 0))])
        XCTAssertEqual(scheduler.tick(now: at(12, 0)), [.hardStopEnded(id: timed.id, reason: .ended)])
        XCTAssertTrue(runTimed(&scheduler, from: at(12, 0), through: at(12, 30), step: 30).filter { isHardStopEvent($0.1) }.isEmpty)

        // The same for a stop without an end.
        let open = hardStop(end: .untilDismissed)
        var untilDismissed = makeScheduler(stops: [open])
        XCTAssertTrue(untilDismissed.tick(now: at(10, 30), inputs: call).isEmpty)
        untilDismissed.calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -3600))
        XCTAssertEqual(untilDismissed.tick(now: at(10, 40)), [.hardStopStarted(id: open.id, endsAt: nil)])
        XCTAssertEqual(untilDismissed.dismissHardStop(now: at(10, 41)), [.hardStopEnded(id: open.id, reason: .dismissed)])
        XCTAssertTrue(runTimed(&untilDismissed, from: at(10, 41), through: at(11, 40), step: 30).filter { isHardStopEvent($0.1) }.isEmpty)
    }

    func testOperationsSeeAStopThatStartedInsideBeforeTheNextTick() {
        // B starts at 10:45 inside A and ends later with no escape hatch. Extending at 10:45, before that tick,
        // follows B's rule.
        let a = hardStop(escapeHatch: .extend(minutes: 15, times: 1))
        let b = hardStop(hour: 10, minute: 45, end: .at(hour: 12, minute: 0), escapeHatch: .none)
        var scheduler = makeScheduler(stops: [a, b])
        _ = runTimed(&scheduler, from: t0, through: at(10, 44, 59))
        XCTAssertTrue(scheduler.extendHardStop(now: at(10, 45)).isEmpty)
        XCTAssertTrue(scheduler.dismissHardStop(now: at(10, 45)).isEmpty)
        XCTAssertEqual(scheduler.phase, .breaking)
        // Refused operations change nothing; the next tick merges B.
        XCTAssertTrue(scheduler.tick(now: at(10, 45)).isEmpty)
        XCTAssertEqual(scheduler.snapshot.breakEndsAt, at(12, 0))
    }

    func testRestoringDeletedStopWhileItRunsDoesNotRecordItTwice() {
        let stop = hardStop()
        var scheduler = makeScheduler(stops: [stop])
        _ = scheduler.tick(now: at(10, 30))
        scheduler.settings.hardStops = []
        XCTAssertTrue(scheduler.tick(now: at(10, 31)).isEmpty)
        scheduler.settings.hardStops = [stop]
        XCTAssertTrue(scheduler.tick(now: at(10, 32)).isEmpty)
        XCTAssertEqual(scheduler.tick(now: at(11, 0)), [.hardStopEnded(id: stop.id, reason: .ended)])
        XCTAssertEqual(scheduler.records.count, 1)
    }

    func testHardStopOnDaylightSavingDayStartsAtNextValidMinute() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // Sunday 8 March 2026: clocks move from 02:00 to 03:00, so 02:30 does not exist.
        let night = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 0)))
        let threeAM = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 0)))
        XCTAssertEqual(threeAM.timeIntervalSince(night), 3600)

        var settings = BreakSettings()
        settings.officeHours.isEnabled = false
        settings.plannedBreaks = []
        settings.workInterval = 4 * 3600
        let stop = hardStop(hour: 2, minute: 30, repeats: .weekdays([1]))
        settings.hardStops = [stop]
        let snapshot = EngineSnapshot(focusStartedAt: night, nextBreakAt: night.addingTimeInterval(4 * 3600), snoozeDay: newYork.startOfDay(for: night))
        var scheduler = BreakScheduler(settings: settings, snapshot: snapshot, records: [], calendar: newYork)
        let events = runTimed(&scheduler, from: night, through: threeAM.addingTimeInterval(60)).filter { isHardStopEvent($0.1) }
        XCTAssertEqual(events.map(\.0), [threeAM])
        XCTAssertEqual(events.map(\.1), [.hardStopStarted(id: stop.id, endsAt: threeAM.addingTimeInterval(30 * 60))])
    }

    func testDaylightSavingStartThatReachesItsEndIsNotAnOvernightStop() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let night = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 0)))
        // 02:30 to 03:00: 02:30 does not exist that night, so the start moves to 03:00, which is also the end.
        let stop = HardStop(name: "Night", hour: 2, minute: 30, end: .at(hour: 3, minute: 0), repeats: .weekdays([1]))
        // The whole window is skipped, so there is no occurrence that night, and not one from 03:00 until 03:00 the next day.
        XCTAssertNil(stop.occurrence(onDayOf: night, calendar: newYork))

        var settings = BreakSettings()
        settings.officeHours.isEnabled = false
        settings.plannedBreaks = []
        settings.hardStops = [stop]
        let snapshot = EngineSnapshot(focusStartedAt: night, nextBreakAt: night.addingTimeInterval(4 * 3600), snoozeDay: newYork.startOfDay(for: night))
        var scheduler = BreakScheduler(settings: settings, snapshot: snapshot, records: [], calendar: newYork)
        XCTAssertTrue(runTimed(&scheduler, from: night, through: night.addingTimeInterval(3 * 3600), step: 30).filter { isHardStopEvent($0.1) }.isEmpty)
    }

    func testHardStopWorkedOutWithCurrentTimeZoneEachTick() throws {
        // The same stop at 10:30 local starts at a different instant once the scheduler's time zone changes.
        let stop = hardStop()
        var scheduler = makeScheduler(stops: [stop])
        scheduler.calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 3600))
        XCTAssertEqual(scheduler.tick(now: at(9, 30)), [.hardStopStarted(id: stop.id, endsAt: at(10, 0))])
    }
}

private extension BreakScheduler {
    var pauseReasonForTest: PauseReason? { snapshot.pauseReason }
}
