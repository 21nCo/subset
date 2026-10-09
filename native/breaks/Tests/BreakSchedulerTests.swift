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
        var scheduler = makeScheduler { $0.reminder.headsUpLeadTime = 60 }
        XCTAssertTrue(run(&scheduler, from: t0, seconds: 20 * 60 - 61).isEmpty)
        XCTAssertEqual(scheduler.tick(now: t0.addingTimeInterval(20 * 60 - 60)), [.headsUp(breakAt: t0.addingTimeInterval(20 * 60))])
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
}

private extension BreakScheduler {
    var pauseReasonForTest: PauseReason? { snapshot.pauseReason }
}
