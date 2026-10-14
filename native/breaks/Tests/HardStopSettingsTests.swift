import XCTest
// Mac only: the BreaksMacTests bundle compiles the shared sources and `Mac/HardStopQuickAdd.swift` directly.

final class HardStopSettingsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let locale = Locale(identifier: "en_GB")

    /// Monday 10 August 2026 at `hour`:`minute` UTC, plus `seconds`, `dayOffset` days later.
    private func at(_ hour: Int, _ minute: Int, _ seconds: Int = 0, dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 10 + dayOffset, hour: hour, minute: minute, second: seconds))!
    }

    private func stop(
        _ name: String = "Lunch",
        hour: Int = 12,
        minute: Int = 30,
        end: HardStop.End = .after(30 * 60),
        repeats: HardStop.Repeat = .weekdays([2]),
        escapeHatch: HardStop.EscapeHatch = .none,
        duringCalls: HardStop.CallBehavior = .startAnyway
    ) -> HardStop {
        HardStop(name: name, hour: hour, minute: minute, end: end, repeats: repeats, warningMinutes: [10],
                 escapeHatch: escapeHatch, duringCalls: duringCalls)
    }

    private func makeScheduler(_ stops: [HardStop], start: Date? = nil) -> BreakScheduler {
        var settings = BreakSettings()
        settings.officeHours.isEnabled = false
        settings.plannedBreaks = []
        settings.workInterval = 8 * 3600
        settings.wellness.blinkEnabled = false
        settings.wellness.postureEnabled = false
        settings.hardStops = stops
        let start = start ?? at(12, 0)
        let snapshot = EngineSnapshot(
            phase: .focusing, focusStartedAt: start, nextBreakAt: start.addingTimeInterval(settings.workInterval),
            snoozeDay: calendar.startOfDay(for: start)
        )
        return BreakScheduler(settings: settings, snapshot: snapshot, records: [], calendar: calendar)
    }

    private func isStart(_ event: BreakScheduler.Event) -> Bool {
        if case .hardStopStarted = event { true } else { false }
    }

    // MARK: - Quick add: times

    func testQuickAddOpensThirtyMinutesAheadRoundedUpToTheNextFiveMinutes() {
        let cases: [(now: Date, hour: Int, minute: Int)] = [
            (at(10, 0), 10, 30),
            (at(10, 5), 10, 35),
            (at(10, 0, 1), 10, 35),
            (at(10, 2, 10), 10, 35),
            (at(10, 4, 59), 10, 35),
            (at(10, 29, 30), 11, 0),
        ]
        for item in cases {
            let values = HardStopQuickAdd(now: item.now, calendar: calendar)
            XCTAssertEqual([values.hour, values.minute], [item.hour, item.minute], "\(item.now)")
            XCTAssertEqual(values.lengthMinutes, 30)
            XCTAssertEqual(values.name, "Hard stop")
            XCTAssertFalse(values.startsTomorrow(now: item.now, calendar: calendar))
        }
    }

    func testQuickAddTimeEarlierThanNowIsTomorrow() {
        let now = at(14, 0, 30)
        var values = HardStopQuickAdd(now: now, calendar: calendar)

        values.hour = 13
        values.minute = 59
        XCTAssertTrue(values.startsTomorrow(now: now, calendar: calendar))
        let tomorrow = values.stop(now: now, calendar: calendar)
        XCTAssertEqual(tomorrow.repeats, .once(DateComponents(year: 2026, month: 8, day: 11)))
        XCTAssertEqual(tomorrow.start(onDayOf: at(0, 0, dayOffset: 1), calendar: calendar), at(13, 59, dayOffset: 1))

        // The current minute is today, and starts at once.
        values.minute = 0
        values.hour = 14
        XCTAssertFalse(values.startsTomorrow(now: now, calendar: calendar))
        XCTAssertEqual(values.stop(now: now, calendar: calendar).repeats, .once(DateComponents(year: 2026, month: 8, day: 10)))

        values.minute = 1
        XCTAssertFalse(values.startsTomorrow(now: now, calendar: calendar))
    }

    func testQuickAddAroundMidnight() {
        // 23:40 + 30 minutes is 00:10, which is earlier than now on the clock, so it is tomorrow.
        let lateEvening = at(23, 40)
        let values = HardStopQuickAdd(now: lateEvening, calendar: calendar)
        XCTAssertEqual([values.hour, values.minute], [0, 10])
        XCTAssertTrue(values.startsTomorrow(now: lateEvening, calendar: calendar))
        let stop = values.stop(now: lateEvening, calendar: calendar)
        XCTAssertEqual(stop.occurrence(onDayOf: at(0, 0, dayOffset: 1), calendar: calendar)?.start, at(0, 10, dayOffset: 1))

        var settings = BreakSettings()
        XCTAssertEqual(settings.saveHardStop(stop, isNew: true, now: lateEvening, calendar: calendar), [])
        XCTAssertEqual(settings.hardStops, [stop])

        // Rounding crosses midnight too.
        let rounded = HardStopQuickAdd(now: at(23, 50, 1), calendar: calendar)
        XCTAssertEqual([rounded.hour, rounded.minute], [0, 25])

        // Just after midnight, a late-evening time is later today, not tomorrow.
        var late = HardStopQuickAdd(now: at(0, 5, dayOffset: 1), calendar: calendar)
        late.hour = 23
        late.minute = 30
        XCTAssertFalse(late.startsTomorrow(now: at(0, 5, dayOffset: 1), calendar: calendar))
    }

    func testQuickAddOnDaylightSavingDays() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func instant(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso)) }

        // Sunday 8 March 2026: clocks go from 2:00 to 3:00. 1:50 EST plus 30 minutes is 3:20 EDT, not 2:20.
        let spring = try instant("2026-03-08T06:50:00Z")
        let values = HardStopQuickAdd(now: spring, calendar: newYork)
        XCTAssertEqual([values.hour, values.minute], [3, 20])
        XCTAssertFalse(values.startsTomorrow(now: spring, calendar: newYork))
        let stop = values.stop(now: spring, calendar: newYork)
        XCTAssertEqual(stop.start(onDayOf: spring, calendar: newYork), spring.addingTimeInterval(30 * 60))

        // A time the clocks skip is still today, at the next time that exists.
        var skipped = values
        skipped.hour = 2
        skipped.minute = 30
        XCTAssertFalse(skipped.startsTomorrow(now: spring, calendar: newYork))
        let start = try XCTUnwrap(skipped.stop(now: spring, calendar: newYork).start(onDayOf: spring, calendar: newYork))
        XCTAssertGreaterThan(start, spring)
        XCTAssertEqual(newYork.dateComponents([.year, .month, .day], from: start), DateComponents(year: 2026, month: 3, day: 8))

        // Sunday 1 November 2026: clocks go back from 2:00 to 1:00. At the second 1:40, 1:50 already came (its first
        // pass is what a stop uses), so it is tomorrow; 2:10 is still ahead today.
        let fall = try instant("2026-11-01T06:40:00Z")
        var repeated = HardStopQuickAdd(now: fall, calendar: newYork)
        XCTAssertEqual([repeated.hour, repeated.minute], [2, 10])
        XCTAssertFalse(repeated.startsTomorrow(now: fall, calendar: newYork))
        repeated.hour = 1
        repeated.minute = 50
        XCTAssertTrue(repeated.startsTomorrow(now: fall, calendar: newYork))
        var settings = BreakSettings()
        XCTAssertEqual(settings.saveHardStop(repeated.stop(now: fall, calendar: newYork), isNew: true, now: fall, calendar: newYork), [])

        // Half an hour from the first 1:40 (EDT) or the second 1:05 (EST) is in the second pass of the repeated hour,
        // which a stop's 1:xx cannot mean. The default moves on to 2:00 EST today rather than an hour already gone.
        for now in try [instant("2026-11-01T05:40:00Z"), instant("2026-11-01T06:05:00Z")] {
            let values = HardStopQuickAdd(now: now, calendar: newYork)
            XCTAssertEqual([values.hour, values.minute], [2, 0])
            XCTAssertFalse(values.startsTomorrow(now: now, calendar: newYork))
            var settings = BreakSettings()
            let quick = values.stop(now: now, calendar: newYork)
            XCTAssertEqual(settings.saveHardStop(quick, isNew: true, now: now, calendar: newYork), [])
            let saved = try XCTUnwrap(settings.hardStops.first { $0.id == quick.id })
            let start = try XCTUnwrap(saved.start(onDayOf: now, calendar: newYork))
            XCTAssertEqual(start, try instant("2026-11-01T07:00:00Z"))
            XCTAssertGreaterThanOrEqual(start, now.addingTimeInterval(30 * 60))
            XCTAssertEqual(newYork.dateComponents([.year, .month, .day], from: start), DateComponents(year: 2026, month: 11, day: 1))
        }
    }

    func testQuickAddWhereClocksGoBackAtMidnight() throws {
        var beirut = Calendar(identifier: .gregorian)
        beirut.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Beirut"))
        func instant(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso)) }

        // Saturday 24 October 2026: at midnight clocks go back to 23:00, so 23:00 to 24:00 comes twice. Half an hour on
        // from 23:40 (first pass), 23:58, or 23:10 (second pass) is in the second pass, which a stop's 23:xx cannot
        // mean; the default is midnight, tomorrow by the calendar, not 23:xx a day later.
        for now in try ["2026-10-24T20:40:00Z", "2026-10-24T20:58:00Z", "2026-10-24T21:10:00Z"].map(instant) {
            let values = HardStopQuickAdd(now: now, calendar: beirut)
            XCTAssertEqual([values.hour, values.minute], [0, 0])
            XCTAssertTrue(values.startsTomorrow(now: now, calendar: beirut))
            var settings = BreakSettings()
            let quick = values.stop(now: now, calendar: beirut)
            XCTAssertEqual(settings.saveHardStop(quick, isNew: true, now: now, calendar: beirut), [])
            XCTAssertEqual(quick.repeats, .once(DateComponents(year: 2026, month: 10, day: 25)))
            let day = try instant("2026-10-24T22:00:00Z")
            XCTAssertEqual(settings.hardStops.first?.start(onDayOf: day, calendar: beirut), day)
        }
    }

    func testQuickAddDefaultIsTheFirstTimeAtLeastHalfAnHourAheadAroundEachClockChange() throws {
        func instant(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso)) }
        let changes = try [
            ("America/New_York", instant("2026-03-08T07:00:00Z")),
            ("America/New_York", instant("2026-11-01T06:00:00Z")),
            ("Asia/Beirut", instant("2026-10-24T21:00:00Z")),
            ("America/Santiago", instant("2026-04-05T03:00:00Z")),
        ]
        for (zone, change) in changes {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            // Every 5 minutes for 3 hours either side, on the minute and between minutes.
            for step in -36...36 {
                for seconds in [0.0, 170.5] {
                    let now = change.addingTimeInterval(TimeInterval(step * 5 * 60) + seconds)
                    let values = HardStopQuickAdd(now: now, calendar: calendar)
                    let quick = values.stop(now: now, calendar: calendar)
                    guard case .once(let date) = quick.repeats else { return XCTFail("\(zone) \(now): not a one-off stop") }
                    let day = try XCTUnwrap(calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)))
                    let start = try XCTUnwrap(quick.start(onDayOf: day, calendar: calendar))
                    let context = "\(zone) \(now): \(values.hour):\(values.minute) starts \(start)"
                    XCTAssertGreaterThanOrEqual(start, now.addingTimeInterval(30 * 60), context)
                    // At most the 5-minute rounding plus the hour the clocks repeat.
                    XCTAssertLessThan(start, now.addingTimeInterval(95 * 60), context)
                    XCTAssertEqual(values.startsTomorrow(now: now, calendar: calendar), !calendar.isDate(start, inSameDayAs: now), context)
                    let clock = calendar.dateComponents([.hour, .minute], from: start)
                    XCTAssertEqual([clock.hour, clock.minute], [values.hour, values.minute], context)
                }
            }
        }
    }

    // MARK: - Quick add: the stop

    func testQuickAddCreatesAOneOffStopWithTheDefaultsThatStartsOnTheNextTick() {
        let now = at(10, 2)
        var values = HardStopQuickAdd(now: now, calendar: calendar)
        values.lengthMinutes = 45
        values.name = "  "
        let quick = values.stop(now: now, calendar: calendar)
        let defaults = HardStop(name: "", hour: 0, minute: 0)
        XCTAssertEqual(quick.name, "Hard stop")
        XCTAssertEqual(quick.end, .after(45 * 60))
        XCTAssertEqual(quick.repeats, .once(DateComponents(year: 2026, month: 8, day: 10)))
        XCTAssertEqual(quick.warningMinutes, defaults.warningMinutes)
        XCTAssertEqual(quick.escapeHatch, defaults.escapeHatch)
        XCTAssertEqual(quick.duringCalls, defaults.duringCalls)

        // Added to the running scheduler's settings, as the controller does, it starts without a relaunch.
        var scheduler = makeScheduler([], start: at(10, 0))
        var settings = scheduler.settings
        XCTAssertEqual(settings.saveHardStop(quick, isNew: true, now: now, calendar: calendar), [])
        scheduler.settings = settings
        XCTAssertEqual(scheduler.tick(now: at(10, 35)).filter(isStart), [.hardStopStarted(id: quick.id, endsAt: at(11, 20))])
    }

    func testQuickAddIsRejectedAtTheLimit() {
        var settings = BreakSettings()
        settings.hardStops = (0..<HardStop.maximumCount).map { stop("Stop \($0)") }
        let before = settings
        let quick = HardStopQuickAdd(now: at(10, 0), calendar: calendar).stop(now: at(10, 0), calendar: calendar)
        XCTAssertEqual(settings.saveHardStop(quick, isNew: true, now: at(10, 0), calendar: calendar),
                       [HardStopFieldError(field: .list, message: "Add at most 20 hard stops.")])
        XCTAssertEqual(settings, before)
    }

    // MARK: - Editor

    func testEditorValuesSaveToAValidHardStop() {
        var draft = HardStopDraft.new(now: at(10, 0))
        draft.name = "Lunch"
        draft.hour = 13
        draft.minute = 0
        draft.endKind = .afterLength
        draft.lengthMinutes = 45
        draft.weekdays = [2, 4]
        draft.warningMinutes = [10, 5]
        draft.escapeKind = .extend
        draft.extendMinutes = 10
        draft.extendTimes = 2
        draft.duringCalls = .startAnyway

        var settings = BreakSettings()
        XCTAssertEqual(settings.saveHardStop(draft.stop(calendar: calendar), isNew: draft.isNew, now: at(10, 0), calendar: calendar), [])
        XCTAssertEqual(settings.hardStops, [HardStop(
            id: draft.id, name: "Lunch", hour: 13, minute: 0, end: .after(45 * 60), repeats: .weekdays([2, 4]),
            warningMinutes: [10, 5], escapeHatch: .extend(minutes: 10, times: 2), duringCalls: .startAnyway
        )])
    }

    func testEditorShowsEachStoredStopAsItIs() {
        let stops = [
            stop(end: .at(hour: 13, minute: 15), repeats: .weekdays([1, 7]), escapeHatch: .dismissEarly, duringCalls: .waitForCallToEnd),
            stop(end: .after(90 * 60), repeats: .once(DateComponents(year: 2026, month: 8, day: 12)), escapeHatch: .extend(minutes: 20, times: 3)),
            stop(end: .untilDismissed, repeats: .weekdays([2, 3]), escapeHatch: .dismissEarly),
            stop(end: .after(30 * 60), escapeHatch: .none),
        ]
        for original in stops {
            let draft = HardStopDraft(original, now: at(10, 0), calendar: calendar)
            XCTAssertFalse(draft.isNew)
            XCTAssertEqual(draft.stop(calendar: calendar), original)
        }
    }

    func testEditingKeepsTheStopsPlaceAndOnOffState() {
        let first = stop("First")
        var second = stop("Second", hour: 15)
        second.isEnabled = false
        var settings = BreakSettings()
        settings.hardStops = [first, second]

        var draft = HardStopDraft(second, now: at(10, 0), calendar: calendar)
        draft.name = "Renamed"
        XCTAssertEqual(settings.saveHardStop(draft.stop(calendar: calendar), isNew: false, now: at(10, 0), calendar: calendar), [])
        XCTAssertEqual(settings.hardStops.map(\.name), ["First", "Renamed"])
        XCTAssertEqual(settings.hardStops[1].id, second.id)
        XCTAssertFalse(settings.hardStops[1].isEnabled)
    }

    func testEachInvalidFieldIsRejectedWithItsError() {
        let cases: [(name: String, edit: (inout HardStopDraft) -> Void, field: HardStopFieldError.Field, message: String)] = [
            ("blank name", { $0.name = "  " }, .name, "Enter a name."),
            ("start hour", { $0.hour = 24 }, .start, "Choose a valid start time."),
            ("end time", { $0.endKind = .atTime; $0.endMinute = 60 }, .end, "Choose a valid end time."),
            ("no length", { $0.endKind = .afterLength; $0.lengthMinutes = 0 }, .end, "A hard stop lasts from 1 minute to 16 hours."),
            ("too long", { $0.endKind = .afterLength; $0.lengthMinutes = 16 * 60 + 1 }, .end, "A hard stop lasts from 1 minute to 16 hours."),
            ("no days", { $0.repeatKind = .weekdays; $0.weekdays = [] }, .repeats, "Choose at least one day."),
            ("past date", { $0.repeatKind = .once; $0.date = self.at(9, 0, dayOffset: -1) }, .repeats, "This date and time have passed."),
            ("passed today", { $0.repeatKind = .once; $0.date = self.at(10, 0); $0.hour = 9 }, .repeats, "This date and time have passed."),
            ("six warnings", { $0.warningMinutes = [1, 2, 3, 4, 5, 6] }, .warningMinutes, "Add at most 5 warnings."),
            ("zero warning", { $0.warningMinutes = [0] }, .warningMinutes, "Warn from 1 to 120 minutes before."),
            ("late warning", { $0.warningMinutes = [121] }, .warningMinutes, "Warn from 1 to 120 minutes before."),
            ("short extension", { $0.escapeKind = .extend; $0.extendMinutes = 4 }, .escapeHatch, "Extend by 5 to 60 minutes, 1 to 5 times."),
            ("many extensions", { $0.escapeKind = .extend; $0.extendTimes = 6 }, .escapeHatch, "Extend by 5 to 60 minutes, 1 to 5 times."),
        ]
        let existing = stop("Existing")
        for item in cases {
            var settings = BreakSettings()
            settings.hardStops = [existing]
            let before = settings
            var draft = HardStopDraft.new(now: at(10, 0))
            item.edit(&draft)
            let errors = settings.saveHardStop(draft.stop(calendar: calendar), isNew: true, now: at(10, 0), calendar: calendar)
            XCTAssertEqual(errors, [HardStopFieldError(stopID: draft.id, field: item.field, message: item.message)], item.name)
            XCTAssertEqual(settings, before, item.name)
        }

        // The 21st stop is rejected for the whole list.
        var full = BreakSettings()
        full.hardStops = (0..<HardStop.maximumCount).map { stop("Stop \($0)") }
        let draft = HardStopDraft.new(now: at(10, 0))
        XCTAssertEqual(full.saveHardStop(draft.stop(calendar: calendar), isNew: true, now: at(10, 0), calendar: calendar),
                       [HardStopFieldError(field: .list, message: "Add at most 20 hard stops.")])
        XCTAssertEqual(full.hardStops.count, HardStop.maximumCount)
    }

    func testOtherStopsErrorsDoNotBlockSaving() {
        // A one-off stop that has passed stays in the settings until the next tick removes it.
        let passed = stop("Passed", hour: 8, repeats: .once(DateComponents(year: 2026, month: 8, day: 10)))
        var settings = BreakSettings()
        settings.hardStops = [passed]
        let draft = HardStopDraft.new(now: at(10, 0))
        XCTAssertEqual(settings.saveHardStop(draft.stop(calendar: calendar), isNew: true, now: at(10, 0), calendar: calendar), [])
        XCTAssertEqual(settings.hardStops.count, 2)
    }

    func testUntilDismissedHidesTheEscapeHatchAndSavesDismissEarly() {
        var draft = HardStopDraft.new(now: at(10, 0))
        draft.escapeKind = .extend
        draft.extendMinutes = 99
        draft.endKind = .untilDismissed
        XCTAssertFalse(draft.showsEscapeHatch)

        var settings = BreakSettings()
        XCTAssertEqual(settings.saveHardStop(draft.stop(calendar: calendar), isNew: true, now: at(10, 0), calendar: calendar), [])
        XCTAssertEqual(settings.hardStops.first?.end, .untilDismissed)
        XCTAssertEqual(settings.hardStops.first?.escapeHatch, .dismissEarly)
    }

    func testRenamingAStopThatLastsUntilDismissedKeepsItsStoredEscapeHatch() {
        // The model and its validation accept an extension on a stop that lasts until dismissed.
        let original = stop(end: .untilDismissed, escapeHatch: .extend(minutes: 20, times: 2))
        var settings = BreakSettings()
        settings.hardStops = [original]
        var draft = HardStopDraft(original, now: at(10, 0), calendar: calendar)
        XCTAssertFalse(draft.showsEscapeHatch)
        draft.name = "Renamed"
        XCTAssertEqual(settings.saveHardStop(draft.stop(calendar: calendar), isNew: false, now: at(10, 0), calendar: calendar), [])
        XCTAssertEqual(settings.hardStops.first?.name, "Renamed")
        XCTAssertEqual(settings.hardStops.first?.escapeHatch, .extend(minutes: 20, times: 2))

        // A stop switched to until dismissed in the editor saves the hidden escape hatch as dismiss early.
        var switched = HardStopDraft(stop(escapeHatch: .extend(minutes: 20, times: 2)), now: at(10, 0), calendar: calendar)
        switched.endKind = .untilDismissed
        XCTAssertEqual(switched.stop(calendar: calendar).escapeHatch, .dismissEarly)
    }

    func testAnEditOfAStopThatIsGoneIsNotSaved() {
        // A one-off stop that ran (or one deleted elsewhere) while its editor was open.
        let ran = stop("Ran", repeats: .once(DateComponents(year: 2026, month: 8, day: 10)))
        var settings = BreakSettings()
        let draft = HardStopDraft(ran, now: at(12, 40), calendar: calendar)
        XCTAssertEqual(settings.saveHardStop(draft.stop(calendar: calendar), isNew: false, now: at(12, 40), calendar: calendar),
                       [HardStopFieldError(stopID: ran.id, field: .list, message: "This hard stop was deleted or has already run.")])
        XCTAssertEqual(settings.hardStops, [])
    }

    // MARK: - Delete

    func testDeletingARunningStopEndsItAndRecordsItAsDismissed() {
        // No escape hatch: the overlay offers no way out, but deleting the stop ends it.
        let lunch = stop(escapeHatch: .none)
        var scheduler = makeScheduler([lunch])
        XCTAssertEqual(scheduler.tick(now: at(12, 30)).filter(isStart).count, 1)
        XCTAssertEqual(scheduler.dismissHardStop(now: at(12, 35)), [])
        XCTAssertTrue(scheduler.isHardStopRunning(id: lunch.id, now: at(12, 35)))

        XCTAssertEqual(scheduler.deleteHardStop(id: lunch.id, now: at(12, 35)), [.hardStopEnded(id: lunch.id, reason: .dismissed)])
        XCTAssertNil(scheduler.snapshot.activeHardStop)
        XCTAssertEqual(scheduler.phase, .focusing)
        XCTAssertEqual(scheduler.settings.hardStops, [])
        let record = scheduler.records.last
        XCTAssertEqual(record?.kind, .hardStop)
        XCTAssertEqual(record?.hardStopEndReason, .dismissed)
        XCTAssertEqual(record?.completed, false)
        XCTAssertEqual(record?.endedAt, at(12, 35))
        XCTAssertEqual(scheduler.tick(now: at(12, 36)).filter(isStart), [])
        XCTAssertNil(scheduler.snapshot.activeHardStop)
    }

    func testDeletingAnExtendedStopEndsItAndRecordsItAsDismissed() {
        let lunch = stop(escapeHatch: .extend(minutes: 15, times: 1))
        var scheduler = makeScheduler([lunch])
        _ = scheduler.tick(now: at(12, 30))
        XCTAssertEqual(scheduler.extendHardStop(now: at(12, 32)), [.hardStopExtended(id: lunch.id, until: at(12, 47))])
        XCTAssertTrue(scheduler.isHardStopRunning(id: lunch.id, now: at(12, 40)))

        XCTAssertEqual(scheduler.deleteHardStop(id: lunch.id, now: at(12, 40)), [.hardStopEnded(id: lunch.id, reason: .dismissed)])
        XCTAssertNil(scheduler.snapshot.activeHardStop)
        XCTAssertEqual(scheduler.records.last?.hardStopEndReason, .dismissed)
        XCTAssertEqual(scheduler.records.last?.extensionsUsed, 1)
        // The extension never runs out into a resumed stop.
        XCTAssertEqual(scheduler.tick(now: at(12, 47)).filter { if case .hardStopResumed = $0 { true } else { false } }, [])
    }

    func testDeletingAStopMergedIntoTheRunningOneEndsTheRunningStop() {
        let long = stop("Long", end: .after(60 * 60))
        let walk = stop("Walk", hour: 12, minute: 45)
        var scheduler = makeScheduler([long, walk])
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.tick(now: at(12, 45))
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.merged.map(\.id), [walk.id])
        XCTAssertTrue(scheduler.isHardStopRunning(id: walk.id, now: at(12, 50)))

        XCTAssertEqual(scheduler.deleteHardStop(id: walk.id, now: at(12, 50)), [.hardStopEnded(id: long.id, reason: .dismissed)])
        XCTAssertNil(scheduler.snapshot.activeHardStop)
        XCTAssertEqual(scheduler.records.suffix(2).map(\.hardStopEndReason), [.dismissed, .dismissed])
        XCTAssertEqual(scheduler.settings.hardStops.map(\.id), [long.id])
        // The kept stop's occurrence stays handled and does not start again.
        XCTAssertEqual(scheduler.tick(now: at(12, 51)).filter(isStart), [])
    }

    func testDeletingAJoinedStopAfterItsOwnEndOnlyRemovesIt() throws {
        // Long runs 12:30 to 13:30; Walk joins it at 12:45 and its own end is 13:15.
        let cases: [(deleteAt: Date, ticks: [Date])] = [
            (at(13, 15), [at(12, 30), at(12, 45)]),
            (at(13, 15), [at(12, 30)]),
            (at(13, 20), [at(12, 30), at(12, 45)]),
            (at(13, 20), [at(12, 30), at(12, 45), at(13, 16)]),
            (at(13, 20), [at(12, 30)]),
        ]
        for (deleteAt, ticks) in cases {
            let label = "delete at \(deleteAt), ticks \(ticks)"
            let long = stop("Long", end: .after(60 * 60))
            let walk = stop("Walk", hour: 12, minute: 45)
            var scheduler = makeScheduler([long, walk])
            for tick in ticks { _ = scheduler.tick(now: tick) }
            XCTAssertFalse(scheduler.isHardStopRunning(id: walk.id, now: deleteAt), label)
            XCTAssertNil(scheduler.runningHardStop(containing: walk.id, now: deleteAt), label)
            XCTAssertTrue(scheduler.isHardStopRunning(id: long.id, now: deleteAt), label)

            XCTAssertEqual(scheduler.deleteHardStop(id: walk.id, now: deleteAt), [], label)
            XCTAssertEqual(scheduler.snapshot.activeHardStop?.id, long.id, label)
            XCTAssertEqual(scheduler.snapshot.activeHardStop?.endsAt, at(13, 30), label)
            XCTAssertEqual(scheduler.phase, .breaking, label)
            XCTAssertEqual(scheduler.settings.hardStops.map(\.id), [long.id], label)
            XCTAssertEqual(scheduler.records, [], label)

            XCTAssertEqual(scheduler.tick(now: at(13, 30)), [.hardStopEnded(id: long.id, reason: .ended)], label)
            let records = scheduler.records
            XCTAssertEqual(records.count, 2, label)
            XCTAssertEqual(records.map(\.hardStopEndReason), [.ended, .ended], label)
            XCTAssertEqual(records.map(\.completed), [true, true], label)
            XCTAssertEqual(records.map(\.startedAt), [at(12, 30), at(12, 45)], label)
            XCTAssertEqual(records.map(\.endedAt), [at(13, 30), at(13, 15)], label)
        }
    }

    func testDeletingAStopWhoseEndHasPassedBeforeTheTickRecordsItAsEnded() {
        for extended in [false, true] {
            // Lunch runs 12:30 to 13:00; no tick comes at or after its end.
            for now in [at(13, 0), at(13, 0).addingTimeInterval(0.5)] {
                let lunch = stop(escapeHatch: .extend(minutes: 15, times: 1))
                var scheduler = makeScheduler([lunch])
                _ = scheduler.tick(now: at(12, 30))
                // Hidden until 13:05, after the stop's end.
                if extended { XCTAssertFalse(scheduler.extendHardStop(now: at(12, 50)).isEmpty) }
                XCTAssertFalse(scheduler.isHardStopRunning(id: lunch.id, now: now))
                XCTAssertNil(scheduler.runningHardStop(containing: lunch.id, now: now))

                XCTAssertEqual(scheduler.deleteHardStop(id: lunch.id, now: now), [.hardStopEnded(id: lunch.id, reason: .ended)])
                XCTAssertNil(scheduler.snapshot.activeHardStop)
                XCTAssertEqual(scheduler.settings.hardStops, [])
                let record = scheduler.records.last
                XCTAssertEqual(record?.hardStopEndReason, .ended, "extended: \(extended)")
                XCTAssertEqual(record?.completed, true)
                XCTAssertEqual(record?.endedAt, at(13, 0))
                XCTAssertEqual(record?.extensionsUsed, extended ? 1 : 0)
            }
        }
    }

    func testDeletingAStopThatIsNotRunningRecordsNothing() {
        let lunch = stop()
        let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
        var scheduler = makeScheduler([lunch, call], start: at(11, 0))
        // Lunch has warned; Call waits for the call that is running.
        _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        XCTAssertNotNil(scheduler.snapshot.hardStopWarnings[lunch.id.uuidString])
        XCTAssertNotNil(scheduler.snapshot.hardStopsWaitingForCall[call.id.uuidString])
        XCTAssertFalse(scheduler.isHardStopRunning(id: call.id, now: at(12, 20)))

        XCTAssertEqual(scheduler.deleteHardStop(id: call.id, now: at(12, 21)), [])
        XCTAssertEqual(scheduler.deleteHardStop(id: lunch.id, now: at(12, 21)), [])
        XCTAssertEqual(scheduler.records, [])
        XCTAssertEqual(scheduler.settings.hardStops, [])
        XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall, [:])
        XCTAssertEqual(scheduler.snapshot.hardStopWarnings, [:])
        XCTAssertEqual(scheduler.tick(now: at(12, 30)).filter(isStart), [])
    }

    func testDeletingOrTurningOffTheLastWaitingStopReleasesTheHeldScheduleAndKeepsTheFocusCountedSoFar() throws {
        for turnOff in [false, true] {
            // The regular break was due at 12:30, while Call waited for the call that is running.
            let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
            var scheduler = makeScheduler([call], start: at(4, 30))
            _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
            XCTAssertNotNil(scheduler.snapshot.hardStopsWaitingForCall[call.id.uuidString])
            let focused = scheduler.stats(now: at(12, 21))
            XCTAssertEqual(focused.focusTime, 471 * 60)

            if turnOff {
                scheduler.settings.hardStops[0].isEnabled = false
                _ = scheduler.tick(now: at(12, 21))
            } else {
                XCTAssertEqual(scheduler.deleteHardStop(id: call.id, now: at(12, 21)), [])
            }
            XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall, [:], "turned off: \(turnOff)")
            XCTAssertEqual(scheduler.phase, .focusing, "turned off: \(turnOff)")
            XCTAssertEqual(scheduler.snapshot.nextBreakAt, at(12, 21).addingTimeInterval(8 * 3600), "turned off: \(turnOff)")
            // The stretch since 4:30 still counts: no record holds it, so it stays the current one.
            let released = scheduler.stats(now: at(12, 21))
            XCTAssertEqual(released.focusTime, focused.focusTime, "turned off: \(turnOff)")
            XCTAssertEqual(released.longestStretch, focused.longestStretch, "turned off: \(turnOff)")
            XCTAssertEqual(released.screenScore, focused.screenScore, "turned off: \(turnOff)")
            let events = scheduler.tick(now: at(12, 31))
            XCTAssertEqual(events.filter { if case .breakStarted = $0 { true } else { false } }, [], "turned off: \(turnOff)")
            XCTAssertEqual(scheduler.records, [], "turned off: \(turnOff)")
            XCTAssertEqual(scheduler.stats(now: at(12, 31)).focusTime, 481 * 60, "turned off: \(turnOff)")

            // After a relaunch the saved snapshot and history give the same statistics and schedule.
            let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONEncoder().encode(scheduler.snapshot))
            let records = try JSONDecoder().decode([BreakRecord].self, from: JSONEncoder().encode(scheduler.records))
            var relaunched = BreakScheduler(settings: scheduler.settings, snapshot: snapshot, records: records, calendar: calendar)
            XCTAssertEqual(relaunched.stats(now: at(12, 32)).focusTime, 482 * 60, "turned off: \(turnOff)")
            XCTAssertEqual(relaunched.stats(now: at(12, 32)).longestStretch, 482 * 60, "turned off: \(turnOff)")
            XCTAssertEqual(relaunched.tick(now: at(12, 32)).filter { if case .breakStarted = $0 { true } else { false } }, [])
        }
    }

    func testAWaitingStopRescheduledAwayFromItsOccurrenceNeverStartsIt() throws {
        // Call (12:00 for 2 hours) waits for the call that is running at 12:20; the regular break was due at 12:30.
        // At 12:21 it is moved to tomorrow, to 15:00, or to Tuesdays only.
        let edits: [(name: String, edit: (inout HardStop) -> Void, newStart: Date)] = [
            ("one-off moved to tomorrow", { $0.repeats = .once(DateComponents(year: 2026, month: 8, day: 11)) }, at(12, 0, dayOffset: 1)),
            ("start moved", { $0.hour = 15 }, at(15, 0)),
            ("today dropped from its days", { $0.repeats = .weekdays([3]) }, at(12, 0, dayOffset: 1)),
        ]
        for (name, edit, newStart) in edits {
            var call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), repeats: .weekdays([2]), duringCalls: .waitForCallToEnd)
            if name.hasPrefix("one-off") { call.repeats = .once(DateComponents(year: 2026, month: 8, day: 10)) }
            var scheduler = makeScheduler([call], start: at(4, 30))
            _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
            let oldKey = try XCTUnwrap(scheduler.snapshot.hardStopsWaitingForCall[call.id.uuidString], name)
            edit(&scheduler.settings.hardStops[0])
            let focused = scheduler.stats(now: at(12, 21)).focusTime

            // Start now on the old occurrence's notice starts nothing, before or after the next tick.
            XCTAssertFalse(scheduler.canStartHardStopEarly(id: call.id, occurrenceKey: oldKey, now: at(12, 21)), name)
            XCTAssertEqual(scheduler.startHardStopEarly(id: call.id, occurrenceKey: oldKey, now: at(12, 21)), [], name)
            XCTAssertNil(scheduler.waitingOccurrence(of: scheduler.settings.hardStops[0]), name)

            // The call ends: the old occurrence does not start, and the held schedule is released.
            let events = scheduler.tick(now: at(12, 25))
            XCTAssertEqual(events.filter(isStart), [], name)
            XCTAssertEqual(events.filter { if case .breakStarted = $0 { true } else { false } }, [], name)
            XCTAssertNil(scheduler.snapshot.activeHardStop, name)
            XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall, [:], name)
            XCTAssertEqual(scheduler.snapshot.nextBreakAt, at(12, 25).addingTimeInterval(8 * 3600), name)
            XCTAssertEqual(scheduler.stats(now: at(12, 21)).focusTime, focused, name)
            XCTAssertEqual(scheduler.records, [], name)
            XCTAssertFalse(scheduler.canStartHardStopEarly(id: call.id, occurrenceKey: oldKey, now: at(12, 26)), name)
            XCTAssertEqual(scheduler.startHardStopEarly(id: call.id, occurrenceKey: oldKey, now: at(12, 26)), [], name)
            XCTAssertEqual(scheduler.tick(now: at(12, 27)).filter(isStart), [], name)

            // The new occurrence still starts on its day.
            XCTAssertEqual(scheduler.tick(now: newStart).filter(isStart), [.hardStopStarted(id: call.id, endsAt: newStart.addingTimeInterval(2 * 3600))], name)
        }
    }

    func testAWaitingStopEditedWithoutMovingItsOccurrenceKeepsWaiting() {
        // A rename or a new length keeps the occurrence, which starts when the call ends.
        let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
        var scheduler = makeScheduler([call], start: at(4, 30))
        _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        scheduler.settings.hardStops[0].name = "Calls done"
        scheduler.settings.hardStops[0].end = .after(3 * 3600)
        XCTAssertNotNil(scheduler.waitingOccurrence(of: scheduler.settings.hardStops[0]))
        XCTAssertEqual(scheduler.tick(now: at(12, 25)).filter(isStart), [.hardStopStarted(id: call.id, endsAt: at(15, 0))])
    }

    func testDeletingOneOfTwoWaitingStopsKeepsTheScheduleHeld() {
        let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
        let other = stop("Other", hour: 12, minute: 10, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
        var scheduler = makeScheduler([call, other], start: at(4, 30))
        _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall.count, 2)

        XCTAssertEqual(scheduler.deleteHardStop(id: call.id, now: at(12, 21)), [])
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, at(12, 30))
        XCTAssertEqual(scheduler.tick(now: at(12, 31), inputs: .init(signals: [.meeting]))
            .filter { if case .breakStarted = $0 { true } else { false } }, [])
    }

    func testDeletingAnotherStopLeavesTheRunningOneAlone() {
        let lunch = stop()
        let later = stop("Later", hour: 16)
        var scheduler = makeScheduler([lunch, later])
        _ = scheduler.tick(now: at(12, 30))
        XCTAssertEqual(scheduler.deleteHardStop(id: later.id, now: at(12, 35)), [])
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.id, lunch.id)
        XCTAssertEqual(scheduler.phase, .breaking)
    }

    // MARK: - Time pickers

    func testTimePickersKeepTimesTheClocksSkipOrRepeatToday() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func instant(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso)) }
        // Noon on the spring-forward day (2:00 to 3:00) and on the fall-back day (2:00 to 1:00), and on an ordinary day.
        for now in try [instant("2026-03-08T16:00:00Z"), instant("2026-11-01T17:00:00Z"), instant("2026-08-10T16:00:00Z")] {
            for hour in 0..<24 {
                for minute in stride(from: 0, to: 60, by: 5) {
                    let date = HardStopClock.date(hour: hour, minute: minute, near: now, calendar: newYork)
                    let time = HardStopClock.time(of: date, calendar: newYork)
                    XCTAssertEqual([time.hour, time.minute], [hour, minute], "\(now)")
                    // A picker that moves the minute on keeps the hour, even in a skipped or repeated hour.
                    let moved = HardStopClock.time(of: date.addingTimeInterval(5 * 60), calendar: newYork)
                    XCTAssertEqual(moved.hour * 60 + moved.minute, (hour * 60 + minute + 5) % (24 * 60), "\(now)")
                }
            }
        }
        // An ordinary day is used as it is.
        let ordinary = try instant("2026-08-10T16:00:00Z")
        XCTAssertEqual(HardStopClock.referenceDay(near: ordinary, calendar: newYork), newYork.startOfDay(for: ordinary))
    }

    // MARK: - Menu bar and summaries

    func testNextHardStopIsTheEarliestUpcomingEnabledOccurrence() {
        var off = stop("Off", hour: 11)
        off.isEnabled = false
        let lunch = stop("Lunch")
        let tomorrow = stop("Early", hour: 9, minute: 0, repeats: .once(DateComponents(year: 2026, month: 8, day: 11)))
        var scheduler = makeScheduler([off, lunch, tomorrow], start: at(10, 0))

        var next = scheduler.nextHardStop(after: at(10, 0))
        XCTAssertEqual(next?.stop.id, lunch.id)
        XCTAssertEqual(next?.start, at(12, 30))
        XCTAssertEqual(next.map { HardStopText.next($0.stop, start: $0.start, now: at(10, 0), locale: locale, calendar: calendar) },
                       "Next hard stop: Lunch at 12:30")

        // While lunch runs, the next is tomorrow's.
        _ = scheduler.tick(now: at(12, 30))
        next = scheduler.nextHardStop(after: at(12, 30))
        XCTAssertEqual(next?.stop.id, tomorrow.id)
        XCTAssertEqual(next.map { HardStopText.next($0.stop, start: $0.start, now: at(12, 30), locale: locale, calendar: calendar) },
                       "Next hard stop: Early at 09:00 tomorrow")

        // A weekly stop is found a week ahead; there is none once no stop is enabled.
        let weekly = makeScheduler([lunch], start: at(13, 0))
        XCTAssertEqual(weekly.nextHardStop(after: at(13, 0))?.start, at(12, 30, dayOffset: 7))
        XCTAssertEqual(HardStopText.next(lunch, start: at(12, 30, dayOffset: 7), now: at(13, 0), locale: locale, calendar: calendar),
                       "Next hard stop: Lunch at 12:30 on Mon 17 Aug")
        XCTAssertNil(makeScheduler([off]).nextHardStop(after: at(10, 0)))
    }

    func testNextHardStopLooksPastAWeekWhoseOccurrenceTheClocksSkip() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // Sundays 2:00 to 2:45: on 8 March 2026 the clocks skip from 2:00 to 3:00, so that week has none.
        let early = stop("Early", hour: 2, minute: 0, end: .at(hour: 2, minute: 45), repeats: .weekdays([1]))
        let base = makeScheduler([early])
        let scheduler = BreakScheduler(settings: base.settings, snapshot: base.snapshot, records: [], calendar: newYork)
        let monday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-02T15:00:00Z"))
        XCTAssertEqual(scheduler.nextHardStop(after: monday)?.start, ISO8601DateFormatter().date(from: "2026-03-15T06:00:00Z"))
    }

    func testRowSummaries() {
        XCTAssertEqual(HardStopText.summary(of: stop(hour: 13, minute: 0, end: .after(45 * 60), repeats: .weekdays([2, 3, 4, 5, 6])),
                                            locale: locale, calendar: calendar), "Weekdays 13:00 · 45 min")
        XCTAssertEqual(HardStopText.summary(of: stop(end: .at(hour: 14, minute: 0), repeats: .weekdays([1, 7])),
                                            locale: locale, calendar: calendar), "Weekends 12:30 · until 14:00")
        XCTAssertEqual(HardStopText.summary(of: stop(end: .untilDismissed, repeats: .weekdays(Set(1...7))),
                                            locale: locale, calendar: calendar), "Every day 12:30 · until dismissed")
        XCTAssertEqual(HardStopText.summary(of: stop(end: .after(90 * 60), repeats: .weekdays([4, 2])),
                                            locale: locale, calendar: calendar), "Mon, Wed 12:30 · 1 hr 30 min")
        XCTAssertEqual(HardStopText.summary(of: stop(end: .after(3600), repeats: .once(DateComponents(year: 2026, month: 8, day: 11))),
                                            locale: locale, calendar: calendar), "Tue 11 Aug 12:30 · 1 hr")
    }
}
