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

    /// The first clock change in `zone` in 2026 after `start` that sets the clocks back, from the time zone data.
    private func fallBack2026(in zone: String, after start: String) throws -> Date? {
        let timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        var date = try XCTUnwrap(ISO8601DateFormatter().date(from: start))
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
        while let next = timeZone.nextDaylightSavingTimeTransition(after: date), next < end {
            if timeZone.secondsFromGMT(for: next) < timeZone.secondsFromGMT(for: next.addingTimeInterval(-1)) { return next }
            date = next
        }
        return nil
    }

    func testQuickAddWhereClocksGoBackAtMidnight() throws {
        var beirut = Calendar(identifier: .gregorian)
        beirut.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Beirut"))
        // Beirut's autumn change (24 October 2026 in current data): at midnight clocks go back to 23:00, so 23:00 to
        // 24:00 comes twice.
        guard let change = try fallBack2026(in: "Asia/Beirut", after: "2026-07-01T00:00:00Z"),
              beirut.dateComponents([.hour, .minute], from: change.addingTimeInterval(-60)) == DateComponents(hour: 23, minute: 59),
              beirut.dateComponents([.hour, .minute], from: change) == DateComponents(hour: 23, minute: 0) else {
            throw XCTSkip("The time zone data has no 2026 Beirut change from midnight back to 23:00")
        }
        let midnight = change.addingTimeInterval(3600)
        let day = beirut.dateComponents([.year, .month, .day], from: midnight)

        // Half an hour on from 23:40 (first pass), 23:58, or 23:10 (second pass) is in the second pass, which a stop's
        // 23:xx cannot mean; the default is midnight, tomorrow by the calendar, not 23:xx a day later.
        for offset in [-20, -2, 10] {
            let now = change.addingTimeInterval(TimeInterval(offset * 60))
            let values = HardStopQuickAdd(now: now, calendar: beirut)
            XCTAssertEqual([values.hour, values.minute], [0, 0])
            XCTAssertTrue(values.startsTomorrow(now: now, calendar: beirut))
            var settings = BreakSettings()
            let quick = values.stop(now: now, calendar: beirut)
            XCTAssertEqual(settings.saveHardStop(quick, isNew: true, now: now, calendar: beirut), [])
            XCTAssertEqual(quick.repeats, .once(DateComponents(year: day.year, month: day.month, day: day.day)))
            XCTAssertEqual(settings.hardStops.first?.start(onDayOf: midnight, calendar: beirut), midnight)
        }
    }

    func testQuickAddDefaultIsTheFirstTimeAtLeastHalfAnHourAheadAroundEachClockChange() throws {
        func instant(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso)) }
        var changes = try [
            ("America/New_York", instant("2026-03-08T07:00:00Z")),
            ("America/New_York", instant("2026-11-01T06:00:00Z")),
        ]
        // Zones whose clocks go back at midnight, from the time zone data.
        var missing: [String] = []
        for (zone, after) in [("Asia/Beirut", "2026-07-01T00:00:00Z"), ("America/Santiago", "2026-01-01T00:00:00Z")] {
            if let change = try fallBack2026(in: zone, after: after) { changes.append((zone, change)) } else { missing.append(zone) }
        }
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
        if !missing.isEmpty {
            throw XCTSkip("The time zone data has no 2026 change back in \(missing.joined(separator: ", "))")
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

    func testTheLengthSteppersOfferEveryLengthAHardStopCanHave() {
        // The editor's and the panel's steppers start from 30 minutes and move by `lengthStep` within `lengthRange`.
        let range = HardStopQuickAdd.lengthRange
        XCTAssertEqual(range, 1...(16 * 60))
        XCTAssertEqual(TimeInterval(range.lowerBound * 60), HardStop.durationRange.lowerBound)
        XCTAssertEqual(TimeInterval(range.upperBound * 60), HardStop.durationRange.upperBound)
        XCTAssertEqual(HardStopQuickAdd(now: at(10, 0), calendar: calendar).lengthMinutes, 30)

        let now = at(10, 0)
        var reachable = Set<Int>()
        var value = 30
        while range.contains(value) { reachable.insert(value); value -= HardStopQuickAdd.lengthStep }
        value = 30
        while range.contains(value) { reachable.insert(value); value += HardStopQuickAdd.lengthStep }
        XCTAssertEqual(reachable, Set(range))

        for minutes in range {
            var values = HardStopQuickAdd(now: now, calendar: calendar)
            values.lengthMinutes = minutes
            let quick = values.stop(now: now, calendar: calendar)
            var draft = HardStopDraft.new(now: now)
            draft.endKind = .afterLength
            draft.lengthMinutes = minutes
            let edited = draft.stop(calendar: calendar)
            for stop in [quick, edited] {
                var settings = BreakSettings()
                XCTAssertEqual(settings.saveHardStop(stop, isNew: true, now: now, calendar: calendar), [], "\(minutes) min")
                XCTAssertEqual(settings.hardStops.first?.end, .after(TimeInterval(minutes * 60)), "\(minutes) min")
            }
        }

        for minutes in [range.lowerBound - 1, range.upperBound + 1] {
            var values = HardStopQuickAdd(now: now, calendar: calendar)
            values.lengthMinutes = minutes
            var settings = BreakSettings()
            let errors = settings.saveHardStop(values.stop(now: now, calendar: calendar), isNew: true, now: now, calendar: calendar)
            XCTAssertEqual(errors.map(\.field), [.end], "\(minutes) min")
            XCTAssertEqual(errors.map(\.message), ["A hard stop lasts from 1 minute to 16 hours."], "\(minutes) min")
            XCTAssertEqual(settings.hardStops, [])
        }
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

    func testAStoredOneOffDayThatDoesNotExistShowsItsErrorUntilADateIsChosen() {
        // Normalizing keeps a day from 1 to 31 in any month, so 31 April can be stored.
        let impossible = stop("Impossible", repeats: .once(DateComponents(year: 2026, month: 4, day: 31)))
        var settings = BreakSettings()
        settings.hardStops = [impossible]
        let before = settings

        var draft = HardStopDraft(impossible, now: at(10, 0), calendar: calendar)
        XCTAssertEqual(draft.repeatKind, .once)
        XCTAssertEqual(draft.stop(calendar: calendar), impossible)
        draft.name = "Renamed"
        XCTAssertEqual(settings.saveHardStop(draft.stop(calendar: calendar), isNew: false, now: at(10, 0), calendar: calendar),
                       [HardStopFieldError(stopID: impossible.id, field: .repeats, message: "Choose a date.")])
        XCTAssertEqual(settings, before)

        draft.date = at(9, 0, dayOffset: 2)
        XCTAssertEqual(settings.saveHardStop(draft.stop(calendar: calendar), isNew: false, now: at(10, 0), calendar: calendar), [])
        XCTAssertEqual(settings.hardStops.first?.name, "Renamed")
        XCTAssertEqual(settings.hardStops.first?.repeats, .once(DateComponents(year: 2026, month: 8, day: 12)))
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

    func testDeletingTheLastWaitingStopReleasesTheHeldScheduleAndKeepsTheFocusCountedSoFar() throws {
        // The regular break was due at 12:30, while Call waited for the call that is running.
        let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
        var scheduler = makeScheduler([call], start: at(4, 30))
        _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        XCTAssertNotNil(scheduler.snapshot.hardStopsWaitingForCall[call.id.uuidString])
        let focused = scheduler.stats(now: at(12, 21))
        XCTAssertEqual(focused.focusTime, 471 * 60)

        XCTAssertEqual(scheduler.deleteHardStop(id: call.id, now: at(12, 21)), [])
        XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall, [:])
        XCTAssertEqual(scheduler.phase, .focusing)
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, at(12, 21).addingTimeInterval(8 * 3600))
        // The stretch since 4:30 still counts: no record holds it, so it stays the current one.
        let released = scheduler.stats(now: at(12, 21))
        XCTAssertEqual(released.focusTime, focused.focusTime)
        XCTAssertEqual(released.longestStretch, focused.longestStretch)
        XCTAssertEqual(released.screenScore, focused.screenScore)
        let events = scheduler.tick(now: at(12, 31))
        XCTAssertEqual(events.filter { if case .breakStarted = $0 { true } else { false } }, [])
        XCTAssertEqual(scheduler.records, [])
        XCTAssertEqual(scheduler.stats(now: at(12, 31)).focusTime, 481 * 60)

        // After a relaunch the saved snapshot and history give the same statistics and schedule.
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONEncoder().encode(scheduler.snapshot))
        let records = try JSONDecoder().decode([BreakRecord].self, from: JSONEncoder().encode(scheduler.records))
        var relaunched = BreakScheduler(settings: scheduler.settings, snapshot: snapshot, records: records, calendar: calendar)
        XCTAssertEqual(relaunched.stats(now: at(12, 32)).focusTime, 482 * 60)
        XCTAssertEqual(relaunched.stats(now: at(12, 32)).longestStretch, 482 * 60)
        XCTAssertEqual(relaunched.tick(now: at(12, 32)).filter { if case .breakStarted = $0 { true } else { false } }, [])
    }

    func testAPauseAfterAReleasedWaitKeepsTheFocusCountedSoFar() throws {
        // Call (12:00 for 2 hours) waits for the call that is running at 12:20, after focus since 4:30. At 12:21 it
        // is deleted; the countdown starts over from 12:21 while the stretch goes on.
        func released(signals: Set<PauseReason>) -> BreakScheduler {
            let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
            var scheduler = makeScheduler([call], start: at(4, 30))
            _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
            _ = scheduler.deleteHardStop(id: call.id, now: at(12, 21))
            _ = scheduler.tick(now: at(12, 21), inputs: .init(signals: signals))
            XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall, [:])
            return scheduler
        }
        func assertFocus(_ scheduler: BreakScheduler, _ minutes: Int, at now: Date, line: UInt = #line) {
            let stats = scheduler.stats(now: now)
            XCTAssertEqual(stats.focusTime, TimeInterval(minutes * 60), line: line)
            XCTAssertEqual(stats.longestStretch, TimeInterval(minutes * 60), line: line)
        }

        // The call is still on at the release, so the timer pauses for it, and resumes a minute after it ends.
        var smart = released(signals: [.meeting])
        XCTAssertEqual(smart.phase, .paused)
        XCTAssertEqual(smart.snapshot.pauseReason, .meeting)
        _ = smart.tick(now: at(12, 30), inputs: .init(signals: [.meeting]))
        XCTAssertEqual(smart.tick(now: at(12, 31)), [.resumed(.meeting)])
        XCTAssertEqual(smart.snapshot.nextBreakAt, at(12, 31).addingTimeInterval(8 * 3600))
        assertFocus(smart, 481, at: at(12, 41))

        // A manual pause from 13:00 to 13:10, with a relaunch while paused.
        var manual = released(signals: [])
        XCTAssertEqual(manual.phase, .focusing)
        assertFocus(manual, 510, at: at(13, 0))
        XCTAssertEqual(manual.pause(now: at(13, 0)), [.paused(.manual)])
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONEncoder().encode(manual.snapshot))
        let records = try JSONDecoder().decode([BreakRecord].self, from: JSONEncoder().encode(manual.records))
        var relaunched = BreakScheduler(settings: manual.settings, snapshot: snapshot, records: records, calendar: calendar)
        _ = relaunched.tick(now: at(13, 5))
        XCTAssertEqual(relaunched.phase, .paused)
        XCTAssertEqual(relaunched.resume(now: at(13, 10)), [.resumed(.manual)])
        // The countdown goes on from the 7 hours 21 minutes it had left at 13:00.
        XCTAssertEqual(relaunched.snapshot.nextBreakAt, at(13, 10).addingTimeInterval(7 * 3600 + 21 * 60))
        assertFocus(relaunched, 520, at: at(13, 20))
        XCTAssertEqual(relaunched.tick(now: at(13, 20)).filter { if case .breakStarted = $0 { true } else { false } }, [])
    }

    func testALongAbsenceAfterAReleasedWaitResetsTheFocusCountedSoFar() {
        // Call waits for the call that is running at 12:20, after focus since 4:30. At 12:21 it is deleted, while the
        // user has been away for 2 minutes: the countdown is full but the stretch is not.
        let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
        var scheduler = makeScheduler([call], start: at(4, 30))
        _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        _ = scheduler.deleteHardStop(id: call.id, now: at(12, 21))
        XCTAssertEqual(scheduler.tick(now: at(12, 21), inputs: .init(idleSeconds: 2 * 60)), [.paused(.idle)])
        XCTAssertEqual(scheduler.snapshot.pausedRemaining, 8 * 3600)
        XCTAssertEqual(scheduler.snapshot.pausedFocus, 469 * 60)

        // Away long enough to reset: the stretch resets once, though the countdown already showed a full interval.
        XCTAssertEqual(scheduler.tick(now: at(12, 46), inputs: .init(idleSeconds: 30 * 60)), [.focusReset])
        XCTAssertEqual(scheduler.snapshot.pausedFocus, 0)
        XCTAssertEqual(scheduler.tick(now: at(12, 46, 1), inputs: .init(idleSeconds: 30 * 60 + 1)), [])
        XCTAssertEqual(scheduler.tick(now: at(12, 47), inputs: .init(idleSeconds: 0)), [.resumed(.idle)])
        XCTAssertEqual(scheduler.snapshot.nextBreakAt, at(12, 47).addingTimeInterval(8 * 3600))
        XCTAssertEqual(scheduler.focusElapsed(now: at(12, 57)), 10 * 60)
    }

    func testAPausedSnapshotSavedBeforeThePausedFocusWasStoredResumesFromItsCountdown() throws {
        var scheduler = makeScheduler([], start: at(12, 0))
        _ = scheduler.pause(now: at(13, 0))
        XCTAssertEqual(scheduler.snapshot.pausedFocus, 3600)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(scheduler.snapshot)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "pausedFocus"))
        let old = try JSONDecoder().decode(EngineSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.pausedFocus)
        XCTAssertEqual(old.pausedRemaining, 7 * 3600)

        var relaunched = BreakScheduler(settings: scheduler.settings, snapshot: old, records: [], calendar: calendar)
        XCTAssertEqual(relaunched.resume(now: at(14, 0)), [.resumed(.manual)])
        XCTAssertEqual(relaunched.snapshot.focusStartedAt, at(13, 0))
        XCTAssertEqual(relaunched.snapshot.nextBreakAt, at(21, 0))
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

    // MARK: - Edits of stops in progress

    /// The key of the occurrence that starts at `hour`:`minute` on the day of `at(hour, minute, dayOffset:)`.
    private func key(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Int {
        HardStop.Occurrence.key(year: 2026, month: 8, day: 10 + dayOffset, hour: hour, minute: minute)
    }

    private let today = HardStop.Repeat.once(DateComponents(year: 2026, month: 8, day: 10))

    private func isHardStopEvent(_ event: BreakScheduler.Event) -> Bool {
        switch event {
        case .hardStopWarning, .hardStopStarted, .hardStopExtended, .hardStopResumed, .hardStopEnded: true
        default: false
        }
    }

    private func moved(_ stop: HardStop, to hour: Int, _ minute: Int) -> HardStop {
        var moved = stop
        moved.hour = hour
        moved.minute = minute
        return moved
    }

    private func hardStopRecords(_ scheduler: BreakScheduler) -> [BreakRecord] {
        scheduler.records.filter { $0.kind == .hardStop }
    }

    /// When the stop with `id` starts next after `now`, as the menu would show it if it were the only stop.
    private func nextHardStop(of id: UUID, in scheduler: BreakScheduler, after now: Date) -> (stop: HardStop, start: Date)? {
        var only = scheduler
        only.settings.hardStops.removeAll { $0.id != id }
        return only.nextHardStop(after: now)
    }

    /// The parts of the history a test compares: when each record starts and ends, and how it ended.
    private func history(_ scheduler: BreakScheduler) -> [String] {
        hardStopRecords(scheduler).map { "\($0.startedAt.formatted(.iso8601)) \($0.endedAt.formatted(.iso8601)) \($0.hardStopEndReason?.rawValue ?? "-") \($0.extensionsUsed ?? 0)" }
    }

    /// Ticks every `step` seconds from `start` (exclusive) through `end` (inclusive) and returns the hard-stop events with
    /// their times. After every tick, no one-off stop is listed whose occurrence is handled (it ran, merged, or was missed,
    /// or an edit superseded it) while it is neither part of the running stop nor waiting for a call.
    private func run(
        _ scheduler: inout BreakScheduler,
        from start: Date,
        through end: Date,
        step: TimeInterval = 60,
        inputs: (Date) -> BreakScheduler.Inputs = { _ in .init() },
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [(Date, BreakScheduler.Event)] {
        var events: [(Date, BreakScheduler.Event)] = []
        var now = start.addingTimeInterval(step)
        while now <= end {
            events += scheduler.tick(now: now, inputs: inputs(now)).filter(isHardStopEvent).map { (now, $0) }
            let snapshot = scheduler.snapshot
            let inProgress = Set((snapshot.activeHardStop.map { [$0.id] + $0.merged.map(\.id) } ?? []).map(\.uuidString))
                .union(snapshot.hardStopsWaitingForCall.keys)
            for stop in scheduler.settings.hardStops where !inProgress.contains(stop.id.uuidString) {
                guard case .once(let date) = stop.repeats else { continue }
                let key = HardStop.Occurrence.key(year: date.year!, month: date.month!, day: date.day!, hour: stop.hour, minute: stop.minute)
                XCTAssertFalse(scheduler.isHandled(stop, HardStop.Occurrence(start: now, end: nil, key: key)),
                               "\(stop.name) is listed at \(now) though its occurrence is handled", file: file, line: line)
            }
            now = now.addingTimeInterval(step)
        }
        return events
    }

    func testAnEditOfAStopInProgressKeepsItsOccurrenceAndAppliesAfterIt() {
        let long = stop("Long", end: .after(60 * 60), escapeHatch: .extend(minutes: 10, times: 1))
        let walk = stop("Walk", hour: 12, minute: 45, escapeHatch: .dismissEarly)
        let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
        let later = stop("Later", hour: 16)
        let inCall: (Date) -> BreakScheduler.Inputs = { [self] in $0 < at(12, 25) ? .init(signals: [.meeting]) : .init() }
        // Each case gets the edited stop in progress and edits it at `editAt`; the stop ends by 14:00.
        let cases: [(name: String, stops: [HardStop], edited: HardStop, start: (inout BreakScheduler) -> Void, editAt: Date)] = [
            ("running", [long, later], long, { _ = $0.tick(now: self.at(12, 30)) }, at(12, 35)),
            ("hidden by an extension", [long, later], long, { scheduler in
                _ = scheduler.tick(now: self.at(12, 30))
                _ = scheduler.extendHardStop(now: self.at(12, 32))
            }, at(12, 35)),
            ("joined", [long, walk, later], walk, { scheduler in
                _ = scheduler.tick(now: self.at(12, 30))
                _ = scheduler.tick(now: self.at(12, 45))
            }, at(12, 50)),
            // Its own part ended at 13:15, but it stays part of Long's occurrence until Long ends.
            ("joined, after its own end", [long, walk, later], walk, { scheduler in
                _ = scheduler.tick(now: self.at(12, 30))
                _ = scheduler.tick(now: self.at(12, 45))
                _ = scheduler.tick(now: self.at(13, 16))
            }, at(13, 20)),
            // The call ends at 12:25: Call starts then and ends at 14:00.
            ("waiting for a call", [call, later], call, { _ = $0.tick(now: self.at(12, 20), inputs: .init(signals: [.meeting])) }, at(12, 21)),
        ]
        let edits: [(name: String, edit: (inout HardStop) -> Void)] = [
            ("name", { $0.name = "Renamed" }),
            ("start later today", { $0.hour = 15 }),
            ("start inside the running stop", { $0.hour = 12; $0.minute = 50 }),
            ("end", { $0.end = .at(hour: 17, minute: 0) }),
            ("repeat", { $0.repeats = .weekdays([2, 3]) }),
            ("warnings", { $0.warningMinutes = [5] }),
            ("escape hatch", { $0.escapeHatch = .dismissEarly }),
            ("during calls", { $0.duringCalls = $0.duringCalls == .startAnyway ? .waitForCallToEnd : .startAnyway }),
            ("turned off", { $0.isEnabled = false }),
        ]

        for item in cases {
            var baseline = makeScheduler(item.stops, start: at(9, 0))
            item.start(&baseline)
            XCTAssertTrue(baseline.isHardStopInProgress(id: item.edited.id, now: item.editAt), item.name)
            for (field, edit) in edits {
                // A stop that waits for a call stops waiting when it is turned off (see below).
                if item.name == "waiting for a call", field == "turned off" { continue }
                let label = "\(item.name), \(field)"
                var unedited = baseline
                var scheduler = baseline
                var edited = item.edited
                edit(&edited)
                let saved = scheduler.saveHardStop(edited, isNew: false, now: item.editAt)
                XCTAssertEqual(saved.errors, [], label)
                XCTAssertEqual(saved.events, [], label)
                XCTAssertEqual(scheduler.settings.hardStops.first { $0.id == edited.id }, edited, label)
                XCTAssertEqual(scheduler.snapshot.activeHardStop, baseline.snapshot.activeHardStop, label)
                XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall, baseline.snapshot.hardStopsWaitingForCall, label)
                XCTAssertEqual(scheduler.canDismissHardStop(now: item.editAt), baseline.canDismissHardStop(now: item.editAt), label)

                // The rest of the day runs as it would have without the edit: the occurrence in progress keeps its end,
                // escape hatch, and records, nothing joins it again, and the edited stop does not start or warn again.
                let expected = run(&unedited, from: item.editAt, through: at(23, 59), inputs: inCall)
                let events = run(&scheduler, from: item.editAt, through: at(23, 59), inputs: inCall)
                XCTAssertEqual(events.map(\.0), expected.map(\.0), label)
                XCTAssertEqual(events.map(\.1), expected.map(\.1), label)
                XCTAssertEqual(history(scheduler), history(unedited), label)
                XCTAssertNil(scheduler.snapshot.activeHardStop, label)
                XCTAssertEqual(scheduler.settings.hardStops.first { $0.id == edited.id }, edited, label)

                // The edit applies from the next day the stop repeats on.
                let next = nextHardStop(of: edited.id, in: scheduler, after: at(23, 59))
                if edited.isEnabled, edited.hour == 15 {
                    XCTAssertEqual(next?.stop.id, edited.id, label)
                    XCTAssertEqual(next?.start, at(15, edited.minute, dayOffset: 7), label)
                    XCTAssertTrue(scheduler.tick(now: at(15, edited.minute, dayOffset: 7)).contains { if case .hardStopStarted(edited.id, _) = $0 { true } else { false } }, label)
                } else if edited.repeats == .weekdays([2, 3]) {
                    XCTAssertEqual(next?.stop.id, edited.id, label)
                    XCTAssertEqual(next?.start, at(edited.hour, edited.minute, dayOffset: 1), label)
                }
            }
        }
    }

    func testARunningOneOffMovedPastItsEndKeepsItsEndAndRunsAtTheNewTime() {
        for hidden in [false, true] {
            let label = hidden ? "hidden by an extension" : "shown"
            // Lunch runs 12:30 to 13:00; at 12:31 it is moved to 14:00.
            let lunch = stop(repeats: today, escapeHatch: .extend(minutes: 15, times: 1))
            var scheduler = makeScheduler([lunch])
            XCTAssertEqual(scheduler.tick(now: at(12, 30)), [.hardStopStarted(id: lunch.id, endsAt: at(13, 0))], label)
            if hidden { XCTAssertEqual(scheduler.extendHardStop(now: at(12, 30, 30)), [.hardStopExtended(id: lunch.id, until: at(12, 45, 30))], label) }
            let running = scheduler.snapshot.activeHardStop
            let moved = moved(lunch, to: 14, 0)
            XCTAssertEqual(scheduler.hardStopInProgressNote(saving: moved, now: at(12, 31)), HardStopText.inProgress, label)
            XCTAssertEqual(scheduler.saveHardStop(moved, isNew: false, now: at(12, 31)).errors, [], label)
            XCTAssertEqual(scheduler.snapshot.activeHardStop, running, label)

            var events = run(&scheduler, from: at(12, 31), through: at(13, 1))
            XCTAssertEqual(events.map(\.0), (hidden ? [at(12, 46)] : []) + [at(13, 0)], label)
            XCTAssertEqual(events.map(\.1), (hidden ? [.hardStopResumed(id: lunch.id)] : []) + [.hardStopEnded(id: lunch.id, reason: .ended)], label)
            XCTAssertEqual(hardStopRecords(scheduler).count, 1, label)
            XCTAssertEqual(scheduler.settings.hardStops, [moved], label)
            XCTAssertEqual(scheduler.nextHardStop(after: at(13, 1))?.stop.id, lunch.id, label)
            XCTAssertEqual(scheduler.nextHardStop(after: at(13, 1))?.start, at(14, 0), label)

            events = run(&scheduler, from: at(13, 1), through: at(14, 31))
            XCTAssertEqual(events.map(\.0), [at(13, 50), at(14, 0), at(14, 30)], label)
            XCTAssertEqual(events.map(\.1), [
                .hardStopWarning(id: lunch.id, occurrenceKey: key(14, 0), startsAt: at(14, 0), waitingForCall: false),
                .hardStopStarted(id: lunch.id, endsAt: at(14, 30)),
                .hardStopEnded(id: lunch.id, reason: .ended),
            ], label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.startedAt), [at(12, 30), at(14, 0)], label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.endedAt), [at(13, 0), at(14, 30)], label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.extensionsUsed), [hidden ? 1 : 0, 0], label)
            XCTAssertEqual(scheduler.settings.hardStops, [], label)
        }
    }

    func testARunningOneOffMovedBeforeItsEndNeverRunsAndIsRemovedWhenItEnds() {
        // Lunch runs 12:30 to 13:00. At 12:31 it is moved inside its own run, or to a time before it that is still open.
        for (hour, minute) in [(12, 45), (12, 15)] {
            let label = "moved to \(hour):\(minute)"
            let lunch = stop(repeats: today)
            var scheduler = makeScheduler([lunch])
            _ = scheduler.tick(now: at(12, 30))
            let moved = moved(lunch, to: hour, minute)
            XCTAssertEqual(scheduler.hardStopInProgressNote(saving: moved, now: at(12, 31)), HardStopText.inProgressSuperseded, label)
            XCTAssertEqual(scheduler.saveHardStop(moved, isNew: false, now: at(12, 31)).errors, [], label)
            XCTAssertNil(scheduler.nextHardStop(after: at(12, 31)), label)

            // It never merges, warns, or starts, and is listed only until the running stop ends.
            XCTAssertEqual(run(&scheduler, from: at(12, 31), through: at(12, 59)).map(\.1), [], label)
            XCTAssertEqual(scheduler.snapshot.activeHardStop?.merged, [], label)
            XCTAssertEqual(scheduler.snapshot.activeHardStop?.endsAt, at(13, 0), label)
            XCTAssertEqual(scheduler.settings.hardStops, [moved], label)
            XCTAssertEqual(scheduler.tick(now: at(13, 0)), [.hardStopEnded(id: lunch.id, reason: .ended)], label)
            XCTAssertEqual(scheduler.settings.hardStops, [], label)
            XCTAssertEqual(run(&scheduler, from: at(13, 0), through: at(14, 0)).map(\.1), [], label)
            XCTAssertEqual(hardStopRecords(scheduler).count, 1, label)
        }
    }

    func testAOneOffThatJoinedTheRunningStopIsMovedAgainstTheRunningStopsEnd() {
        // Long runs 12:30 to 13:30; the one-off Walk (12:45 to 13:15) joins it. At 12:50 Walk is moved: to a time at or
        // after Long's end it runs then; to an earlier one, even after its own end, it is superseded.
        let long = stop("Long", end: .after(60 * 60), escapeHatch: .extend(minutes: 10, times: 1))
        let walk = stop("Walk", hour: 12, minute: 45, repeats: today, escapeHatch: .dismissEarly)
        let longEnded = BreakScheduler.Event.hardStopEnded(id: long.id, reason: .ended)
        let walkEnded = BreakScheduler.Event.hardStopEnded(id: walk.id, reason: .ended)
        func warning(_ hour: Int, _ minute: Int) -> BreakScheduler.Event {
            .hardStopWarning(id: walk.id, occurrenceKey: key(hour, minute), startsAt: at(hour, minute), waitingForCall: false)
        }
        let cases: [(hour: Int, minute: Int, expected: [(Date, BreakScheduler.Event)])] = [
            (14, 0, [(at(13, 30), longEnded), (at(13, 50), warning(14, 0)),
                     (at(14, 0), .hardStopStarted(id: walk.id, endsAt: at(14, 30))), (at(14, 30), walkEnded)]),
            (13, 40, [(at(13, 30), longEnded), (at(13, 30), warning(13, 40)),
                      (at(13, 40), .hardStopStarted(id: walk.id, endsAt: at(14, 10))), (at(14, 10), walkEnded)]),
            (13, 30, [(at(13, 20), warning(13, 30)), (at(13, 30), longEnded),
                      (at(13, 30), .hardStopStarted(id: walk.id, endsAt: at(14, 0))), (at(14, 0), walkEnded)]),
            (13, 20, [(at(13, 30), longEnded)]),
            (13, 10, [(at(13, 30), longEnded)]),
        ]
        for item in cases {
            let label = "moved to \(item.hour):\(item.minute)"
            var scheduler = makeScheduler([long, walk])
            _ = scheduler.tick(now: at(12, 30))
            _ = scheduler.tick(now: at(12, 45))
            let running = scheduler.snapshot.activeHardStop
            XCTAssertEqual(running?.merged.map(\.id), [walk.id], label)
            XCTAssertEqual(scheduler.saveHardStop(moved(walk, to: item.hour, item.minute), isNew: false, now: at(12, 50)).errors, [], label)
            XCTAssertEqual(scheduler.snapshot.activeHardStop, running, label)

            // Long keeps its end and escape hatch, and Walk does not join it again.
            let events = run(&scheduler, from: at(12, 50), through: at(15, 0))
            XCTAssertEqual(events.map(\.0), item.expected.map(\.0), label)
            XCTAssertEqual(events.map(\.1), item.expected.map(\.1), label)
            let runs = item.expected.count > 1
            let start = at(item.hour, item.minute)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.startedAt), [at(12, 30), at(12, 45)] + (runs ? [start] : []), label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.endedAt), [at(13, 30), at(13, 15)] + (runs ? [start.addingTimeInterval(30 * 60)] : []), label)
            XCTAssertEqual(scheduler.settings.hardStops.map(\.id), [long.id], label)
        }
    }

    func testAOneOffMovedPastTheRunningStopsEndIsSupersededWhenAnotherStopExtendsIt() {
        // Long runs 12:30 to 13:30, and the one-off Walk joins it at 12:45. At 12:50 Walk is moved to 13:40, after Long's
        // end, but Late (13:20 to 14:30) then joins Long and extends it past 13:40, so Walk would join it again. The
        // result is the same whether every tick runs or the host sleeps from 12:50 to 13:45.
        for asleep in [false, true] {
            let label = asleep ? "asleep" : "awake"
            let long = stop("Long", end: .after(60 * 60))
            let walk = stop("Walk", hour: 12, minute: 45, repeats: today)
            let late = stop("Late", hour: 13, minute: 20, end: .at(hour: 14, minute: 30))
            var scheduler = makeScheduler([long, walk, late])
            _ = scheduler.tick(now: at(12, 30))
            _ = scheduler.tick(now: at(12, 45))
            XCTAssertEqual(scheduler.saveHardStop(moved(walk, to: 13, 40), isNew: false, now: at(12, 50)).errors, [], label)
            XCTAssertEqual(nextHardStop(of: walk.id, in: scheduler, after: at(12, 50))?.start, at(13, 40), label)
            let events = asleep
                ? scheduler.tick(now: at(13, 45)).filter(isHardStopEvent) + run(&scheduler, from: at(13, 45), through: at(15, 0)).map(\.1)
                : run(&scheduler, from: at(12, 50), through: at(15, 0)).map(\.1)
            XCTAssertEqual(events, [.hardStopEnded(id: long.id, reason: .ended)], label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.startedAt), [at(12, 30), at(12, 45), at(13, 20)], label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.endedAt), [at(14, 30), at(13, 15), at(14, 30)], label)
            XCTAssertEqual(scheduler.settings.hardStops.map(\.id), [long.id, late.id], label)
        }
    }

    func testAOneOffMovedToAnotherDateWhileItRunsRunsOnThatDate() {
        let lunch = stop(repeats: today)
        var scheduler = makeScheduler([lunch])
        _ = scheduler.tick(now: at(12, 30))
        var moved = lunch
        moved.repeats = .once(DateComponents(year: 2026, month: 8, day: 11))
        XCTAssertEqual(scheduler.saveHardStop(moved, isNew: false, now: at(12, 31)).errors, [])
        XCTAssertEqual(run(&scheduler, from: at(12, 31), through: at(12, 30, dayOffset: 1)).map(\.1), [
            .hardStopEnded(id: lunch.id, reason: .ended),
            .hardStopWarning(id: lunch.id, occurrenceKey: key(12, 30, dayOffset: 1), startsAt: at(12, 30, dayOffset: 1), waitingForCall: false),
            .hardStopStarted(id: lunch.id, endsAt: at(13, 0, dayOffset: 1)),
        ])
        XCTAssertEqual(hardStopRecords(scheduler).count, 1)
    }

    func testAOneOffInProgressAfterItsOwnTimeCanStillBeEdited() {
        // The one-off Walk (12:45 to 13:15) joins Long (12:30 to 13:30), and Big (12:40 to 13:40) joins the running one-off
        // Lunch (12:30 to 13:00) and moves its end to 13:40. After its own end each can still be renamed or given another
        // end or escape hatch: the running stop keeps its end and records, and the stop is removed when it ends.
        let long = stop("Long", end: .after(60 * 60))
        let walk = stop("Walk", hour: 12, minute: 45, repeats: today)
        let lunch = stop("Lunch", repeats: today)
        let big = stop("Big", hour: 12, minute: 40, end: .after(60 * 60))
        let cases: [(name: String, stops: [HardStop], edited: HardStop, editAt: Date, endsAt: Date)] = [
            ("joined", [long, walk], walk, at(13, 20), at(13, 30)),
            ("running, extended by a join", [lunch, big], lunch, at(13, 10), at(13, 40)),
        ]
        let edits: [(name: String, edit: (inout HardStop) -> Void)] = [
            ("name", { $0.name = "Renamed" }),
            ("end", { $0.end = .after(10 * 60) }),
            ("escape hatch", { $0.escapeHatch = .dismissEarly }),
        ]
        for item in cases {
            for (field, edit) in edits {
                let label = "\(item.name), \(field)"
                var scheduler = makeScheduler(item.stops)
                _ = run(&scheduler, from: at(12, 29), through: item.editAt)
                let running = scheduler.snapshot.activeHardStop
                XCTAssertEqual(running?.endsAt, item.endsAt, label)
                var edited = item.edited
                edit(&edited)
                XCTAssertEqual(scheduler.hardStopErrors(saving: edited, isNew: false, now: item.editAt), [], label)
                XCTAssertEqual(scheduler.hardStopInProgressNote(saving: edited, now: item.editAt), HardStopText.inProgress, label)
                // A time moved to one that has passed is judged as any other.
                XCTAssertEqual(scheduler.hardStopErrors(saving: moved(edited, to: 12, 0), isNew: false, now: item.editAt).map(\.field), [.repeats], label)
                XCTAssertTrue(scheduler.saveHardStop(edited, isNew: false, now: item.editAt) == ([], []), label)
                XCTAssertEqual(scheduler.snapshot.activeHardStop, running, label)
                XCTAssertEqual(scheduler.settings.hardStops.first { $0.id == edited.id }, edited, label)

                let events = run(&scheduler, from: item.editAt, through: at(15, 0))
                XCTAssertEqual(events.map(\.0), [item.endsAt], label)
                XCTAssertEqual(events.map(\.1), [.hardStopEnded(id: running?.id ?? UUID(), reason: .ended)], label)
                XCTAssertEqual(hardStopRecords(scheduler).count, 2, label)
                XCTAssertEqual(scheduler.settings.hardStops.map(\.id), item.stops.map(\.id).filter { $0 != edited.id }, label)
            }
        }
    }

    func testAnEditOfAStopWaitingForACallKeepsTheWaitingOccurrence() throws {
        // Call (12:00 for 2 hours, no escape hatch) waits for the call that runs until 12:40. At 12:21 it is renamed,
        // moved to 12:50, shortened to 30 minutes, set to start anyway, and given an escape hatch.
        let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), escapeHatch: .none, duringCalls: .waitForCallToEnd)
        var edited = moved(call, to: 12, 50)
        edited.name = "Standup"
        edited.end = .after(30 * 60)
        edited.duringCalls = .startAnyway
        edited.escapeHatch = .dismissEarly
        let inCall: (Date) -> BreakScheduler.Inputs = { [self] in $0 < at(12, 40) ? .init(signals: [.meeting]) : .init() }
        for relaunched in [false, true] {
            let label = relaunched ? "relaunched while waiting" : "running"
            var scheduler = makeScheduler([call], start: at(9, 0))
            _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
            XCTAssertTrue(scheduler.saveHardStop(edited, isNew: false, now: at(12, 21)) == ([], []), label)
            XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall, [call.id.uuidString: key(12, 0)], label)
            XCTAssertEqual(scheduler.hardStopOccurrence(edited, key: key(12, 0))?.end, at(14, 0), label)
            XCTAssertEqual(scheduler.nextHardStop(after: at(12, 21))?.start, at(12, 50, dayOffset: 7), label)
            if relaunched {
                let settings = try JSONDecoder().decode(BreakSettings.self, from: JSONEncoder().encode(scheduler.settings))
                let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONEncoder().encode(scheduler.snapshot))
                scheduler = BreakScheduler(settings: settings, snapshot: snapshot, records: scheduler.records, calendar: calendar)
                scheduler.reconcileRestoredState(now: at(12, 22))
            }

            // It keeps waiting through the call, starts when the call ends with the end and escape hatch it waited with,
            // and the edited time neither warns nor joins it that day.
            let events = run(&scheduler, from: at(12, 21), through: at(23, 59), inputs: inCall)
            XCTAssertEqual(events.map(\.0), [at(12, 40), at(14, 0)], label)
            XCTAssertEqual(events.map(\.1), [.hardStopStarted(id: call.id, endsAt: at(14, 0)), .hardStopEnded(id: call.id, reason: .ended)], label)
            XCTAssertEqual(hardStopRecords(scheduler).count, 1, label)
            XCTAssertEqual(hardStopRecords(scheduler).first?.startedAt, at(12, 40), label)
            XCTAssertEqual(scheduler.snapshot.hardStopWaitingRules, [:], label)
            XCTAssertEqual(scheduler.nextHardStop(after: at(23, 59))?.start, at(12, 50, dayOffset: 7), label)
        }

        // While it runs, the escape hatch it waited with applies, under its new name.
        var scheduler = makeScheduler([call], start: at(9, 0))
        _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        _ = scheduler.saveHardStop(edited, isNew: false, now: at(12, 21))
        _ = run(&scheduler, from: at(12, 21), through: at(12, 40), inputs: inCall)
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.name, "Standup")
        XCTAssertFalse(scheduler.canDismissHardStop(now: at(12, 41)))

        // A wait saved by an earlier build, without the rules it waited with, keeps the rules its stop has when it is
        // first edited.
        var legacy = makeScheduler([call], start: at(9, 0))
        _ = legacy.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy.snapshot)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "hardStopWaitingRules"))
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(snapshot.hardStopWaitingRules, [:])
        XCTAssertEqual(snapshot.hardStopsWaitingForCall, [call.id.uuidString: key(12, 0)])
        legacy = BreakScheduler(settings: legacy.settings, snapshot: snapshot, records: [], calendar: calendar)
        legacy.reconcileRestoredState(now: at(12, 21))
        XCTAssertTrue(legacy.saveHardStop(edited, isNew: false, now: at(12, 21)) == ([], []))
        XCTAssertEqual(legacy.hardStopOccurrence(edited, key: key(12, 0))?.end, at(14, 0))
        var events = run(&legacy, from: at(12, 21), through: at(12, 41), inputs: inCall)
        XCTAssertFalse(legacy.canDismissHardStop(now: at(12, 41)))
        events += run(&legacy, from: at(12, 41), through: at(23, 59), inputs: inCall)
        XCTAssertEqual(events.map(\.0), [at(12, 40), at(14, 0)])
        XCTAssertEqual(events.map(\.1), [.hardStopStarted(id: call.id, endsAt: at(14, 0)), .hardStopEnded(id: call.id, reason: .ended)])
    }

    func testMalformedRulesOfARestoredWaitAreBroughtIntoRange() throws {
        // Call (12:00 for 2 hours, extend 10 minutes once) waits for the call that runs until 12:40. The rules it waits
        // with are restored malformed; it starts when the call ends with them brought into range, and can be extended.
        let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), escapeHatch: .extend(minutes: 10, times: 1), duringCalls: .waitForCallToEnd)
        let inCall: (Date) -> BreakScheduler.Inputs = { [self] in $0 < at(12, 40) ? .init(signals: [.meeting]) : .init() }
        let cases: [(name: String, edit: (inout HardStop) -> Void, endsAt: Date, escapeHatch: HardStop.EscapeHatch)] = [
            ("extension too long", { $0.escapeHatch = .extend(minutes: .max, times: 1) }, at(14, 0), .extend(minutes: 60, times: 1)),
            ("extension too short, too many", { $0.escapeHatch = .extend(minutes: .min, times: .max) }, at(14, 0), .extend(minutes: 5, times: 5)),
            ("length", { $0.end = .after(.greatestFiniteMagnitude) }, at(4, 0, dayOffset: 1), .extend(minutes: 10, times: 1)),
            ("end time", { $0.end = .at(hour: 99, minute: -5) }, at(23, 0), .extend(minutes: 10, times: 1)),
            ("start time", { $0.hour = 99; $0.minute = -1 }, at(14, 0), .extend(minutes: 10, times: 1)),
        ]
        for item in cases {
            var scheduler = makeScheduler([call], start: at(9, 0))
            _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
            var snapshot = scheduler.snapshot
            item.edit(&snapshot.hardStopWaitingRules[call.id.uuidString]!)
            snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONEncoder().encode(snapshot))
            scheduler = BreakScheduler(settings: scheduler.settings, snapshot: snapshot, records: [], calendar: calendar)
            scheduler.reconcileRestoredState(now: at(12, 21))
            XCTAssertEqual(scheduler.hardStopOccurrence(call, key: key(12, 0))?.end, item.endsAt, item.name)

            let events = run(&scheduler, from: at(12, 21), through: at(12, 40), inputs: inCall)
            XCTAssertEqual(events.map(\.1), [.hardStopStarted(id: call.id, endsAt: item.endsAt)], item.name)
            XCTAssertEqual(scheduler.snapshot.activeHardStop?.escapeHatch, item.escapeHatch, item.name)
            guard case .extend(let minutes, _) = item.escapeHatch else { continue }
            XCTAssertEqual(scheduler.extendHardStop(now: at(12, 41)), [.hardStopExtended(id: call.id, until: at(12, 41).addingTimeInterval(TimeInterval(minutes * 60)))], item.name)
        }
    }

    func testAOneOffWaitingForACallThatIsMovedRunsAfterItOrIsRemoved() {
        // The one-off Call (12:00 to 13:00) waits for the call that is running at 12:20. At 12:21 it is moved past its
        // end (14:00) or before it (12:45); the call ends at 12:40, or after Call's end, at 13:05.
        let call = stop("Call", hour: 12, minute: 0, end: .after(60 * 60), repeats: today, duringCalls: .waitForCallToEnd)
        let started = BreakScheduler.Event.hardStopStarted(id: call.id, endsAt: at(13, 0))
        let ended = BreakScheduler.Event.hardStopEnded(id: call.id, reason: .ended)
        let missed = BreakScheduler.Event.hardStopEnded(id: call.id, reason: .missed)
        let atTwo: [(Date, BreakScheduler.Event)] = [
            (at(13, 50), .hardStopWarning(id: call.id, occurrenceKey: key(14, 0), startsAt: at(14, 0), waitingForCall: false)),
            (at(14, 0), .hardStopStarted(id: call.id, endsAt: at(15, 0))), (at(15, 0), ended),
        ]
        let cases: [(hour: Int, minute: Int, callEnds: Date, expected: [(Date, BreakScheduler.Event)], records: [HardStopEndReason])] = [
            (14, 0, at(12, 40), [(at(12, 40), started), (at(13, 0), ended)] + atTwo, [.ended, .ended]),
            (14, 0, at(13, 5), [(at(13, 0), missed)] + atTwo, [.missed, .ended]),
            (12, 45, at(12, 40), [(at(12, 40), started), (at(13, 0), ended)], [.ended]),
            (12, 45, at(13, 5), [(at(13, 0), missed)], [.missed]),
        ]
        for item in cases {
            let label = "moved to \(item.hour):\(item.minute), call until \(item.callEnds)"
            var scheduler = makeScheduler([call], start: at(9, 0))
            _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
            XCTAssertEqual(scheduler.saveHardStop(moved(call, to: item.hour, item.minute), isNew: false, now: at(12, 21)).errors, [], label)
            let events = run(&scheduler, from: at(12, 21), through: at(23, 59)) { $0 < item.callEnds ? .init(signals: [.meeting]) : .init() }
            XCTAssertEqual(events.map(\.0), item.expected.map(\.0), label)
            XCTAssertEqual(events.map(\.1), item.expected.map(\.1), label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.hardStopEndReason), item.records, label)
            XCTAssertEqual(scheduler.settings.hardStops, [], label)
        }
    }

    func testTurningOffARunningOrJoinedStopKeepsItsOccurrenceAndRecordsItOnce() {
        // Long runs 12:30 to 13:30; Walk (12:45 to 13:15) joins it.
        let long = stop("Long", end: .after(60 * 60))
        let walk = stop("Walk", hour: 12, minute: 45)
        var scheduler = makeScheduler([long, walk])
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.tick(now: at(12, 45))
        let running = scheduler.snapshot.activeHardStop

        // Turning Long off keeps it running. Walk, turned off after its own end and back on at another time, does not
        // join again.
        XCTAssertEqual(scheduler.setHardStop(id: long.id, isEnabled: false, now: at(12, 50)), [])
        XCTAssertEqual(scheduler.setHardStop(id: walk.id, isEnabled: false, now: at(13, 20)), [])
        XCTAssertEqual(scheduler.snapshot.activeHardStop, running)
        _ = scheduler.tick(now: at(13, 21))
        XCTAssertEqual(scheduler.saveHardStop(moved(walk, to: 13, 22), isNew: false, now: at(13, 21)).errors, [])
        XCTAssertEqual(scheduler.setHardStop(id: walk.id, isEnabled: true, now: at(13, 21)), [])
        XCTAssertEqual(run(&scheduler, from: at(13, 21), through: at(23, 59)).map(\.1), [.hardStopEnded(id: long.id, reason: .ended)])
        XCTAssertEqual(hardStopRecords(scheduler).map(\.startedAt), [at(12, 30), at(12, 45)])
        XCTAssertEqual(hardStopRecords(scheduler).map(\.endedAt), [at(13, 30), at(13, 15)])
        XCTAssertEqual(hardStopRecords(scheduler).map(\.hardStopEndReason), [.ended, .ended])
    }

    func testTurningOffAStopWaitingForACallReleasesTheHeldScheduleAndAnIdleResetClearsTheFocus() {
        // The regular break was due at 12:30, while Call waited for the call that is running; focus since 4:30.
        let call = stop("Call", hour: 12, minute: 0, end: .after(2 * 3600), duringCalls: .waitForCallToEnd)
        func waiting() -> BreakScheduler {
            var scheduler = makeScheduler([call], start: at(4, 30))
            _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
            XCTAssertEqual(scheduler.stats(now: at(12, 21)).focusTime, 471 * 60)
            XCTAssertEqual(scheduler.setHardStop(id: call.id, isEnabled: false, now: at(12, 21)), [])
            return scheduler
        }

        // The wait ends unrecorded on the next tick; the countdown starts over and the stretch goes on.
        var released = waiting()
        XCTAssertEqual(released.tick(now: at(12, 21)), [])
        XCTAssertEqual(released.snapshot.hardStopsWaitingForCall, [:])
        XCTAssertEqual(released.snapshot.nextBreakAt, at(12, 21).addingTimeInterval(8 * 3600))
        XCTAssertEqual(released.stats(now: at(12, 31)).focusTime, 481 * 60)
        XCTAssertEqual(released.tick(now: at(12, 31)).filter { if case .breakStarted = $0 { true } else { false } }, [])
        XCTAssertEqual(released.records, [])
        XCTAssertEqual(released.settings.hardStops.map(\.id), [call.id])

        // Away from 12:19: an idle pause keeps the stretch apart from the full countdown, and a long absence clears both.
        var idle = waiting()
        XCTAssertEqual(idle.tick(now: at(12, 21), inputs: .init(idleSeconds: 2 * 60)), [.paused(.idle)])
        XCTAssertEqual(idle.snapshot.pausedRemaining, 8 * 3600)
        XCTAssertEqual(idle.snapshot.pausedFocus, 469 * 60)
        XCTAssertEqual(idle.tick(now: at(12, 46), inputs: .init(idleSeconds: 27 * 60)), [.focusReset])
        XCTAssertEqual(idle.snapshot.pausedFocus, 0)
        XCTAssertEqual(idle.tick(now: at(12, 46, 1), inputs: .init(idleSeconds: 27 * 60 + 1)), [])
        XCTAssertEqual(idle.tick(now: at(12, 47)), [.resumed(.idle)])
        XCTAssertEqual(idle.focusElapsed(now: at(12, 57)), 10 * 60)
    }

    func testAnIdleResetAfterAnEditedStopEndsClearsTheFocus() {
        // Lunch runs 12:30 to 13:00 and is moved to 15:00 at 12:31; afterwards the user is away for half an hour.
        let lunch = stop(repeats: today)
        var scheduler = makeScheduler([lunch], start: at(9, 0))
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.saveHardStop(moved(lunch, to: 15, 0), isNew: false, now: at(12, 31))
        XCTAssertEqual(scheduler.tick(now: at(13, 0)), [.hardStopEnded(id: lunch.id, reason: .ended)])
        XCTAssertEqual(scheduler.tick(now: at(13, 10), inputs: .init(idleSeconds: 2 * 60)), [.paused(.idle)])
        XCTAssertEqual(scheduler.snapshot.pausedFocus, 8 * 60)
        XCTAssertEqual(scheduler.tick(now: at(13, 35), inputs: .init(idleSeconds: 27 * 60)), [.focusReset])
        XCTAssertEqual(scheduler.snapshot.pausedFocus, 0)
        XCTAssertEqual(scheduler.snapshot.pausedRemaining, 8 * 3600)
        XCTAssertEqual(scheduler.tick(now: at(13, 36)), [.resumed(.idle)])
        XCTAssertEqual(scheduler.focusElapsed(now: at(13, 46)), 10 * 60)
    }

    func testAnEditSavedAfterAStopStartedInsideTheRunningOneAppliesAfterIt() {
        // Long runs 12:30 to 13:30; Walk starts inside it at 12:45, but the last tick ran at 12:44:59.
        let long = stop("Long", end: .after(60 * 60), escapeHatch: .extend(minutes: 10, times: 1))
        let walk = stop("Walk", hour: 12, minute: 45, escapeHatch: .dismissEarly)
        var later = walk
        later.end = .at(hour: 15, minute: 0)
        later.escapeHatch = .none
        var scheduler = makeScheduler([long, walk], start: at(9, 0))
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.tick(now: at(12, 44, 59))
        XCTAssertFalse(scheduler.isHardStopInProgress(id: walk.id, now: at(12, 44, 59)))
        XCTAssertTrue(scheduler.isHardStopInProgress(id: walk.id, now: at(12, 45)))

        // Saved before Walk starts, the edit applies to it: it joins with its new end and escape hatch.
        var before = scheduler
        XCTAssertTrue(before.saveHardStop(later, isNew: false, now: at(12, 44, 59)) == ([], []))
        _ = before.tick(now: at(12, 45, 1))
        XCTAssertEqual(before.snapshot.activeHardStop?.endsAt, at(15, 0))
        XCTAssertEqual(before.snapshot.activeHardStop?.escapeHatch, HardStop.EscapeHatch.none)

        // Saved once it has started, Walk joins Long as it was, and the edit applies after it.
        var after = scheduler
        XCTAssertTrue(after.saveHardStop(later, isNew: false, now: at(12, 45)) == ([], []))
        XCTAssertEqual(after.snapshot.activeHardStop?.merged.map(\.id), [walk.id])
        XCTAssertEqual(after.snapshot.activeHardStop?.merged.first?.endsAt, at(13, 15))
        _ = after.tick(now: at(12, 45, 1))
        XCTAssertEqual(after.snapshot.activeHardStop?.endsAt, at(13, 30))
        XCTAssertEqual(after.snapshot.activeHardStop?.escapeHatch, .extend(minutes: 10, times: 1))
        XCTAssertEqual(after.tick(now: at(13, 30)), [.hardStopEnded(id: long.id, reason: .ended)])
        XCTAssertEqual(after.records.map(\.endedAt), [at(13, 30), at(13, 15)])
    }

    private let daily = HardStop.Repeat.weekdays(Set(1...7))

    private func warning(_ stop: HardStop, _ hour: Int, _ minute: Int, dayOffset: Int = 0) -> BreakScheduler.Event {
        .hardStopWarning(id: stop.id, occurrenceKey: key(hour, minute, dayOffset: dayOffset), startsAt: at(hour, minute, dayOffset: dayOffset),
                         waitingForCall: false)
    }

    func testARepeatingStopEditedAfterMidnightNeverJoinsTheOccurrenceThatRunsIntoThatDay() {
        // Nightly runs every day from 23:00 for 2 hours, so Monday's runs until 01:00 on Tuesday. After midnight it is moved
        // to a time on Tuesday before 01:00, one that has started or one still to come: neither joins Monday's, and the new
        // time applies from Wednesday.
        for (saveAt, hour, minute) in [(at(0, 30, dayOffset: 1), 0, 15), (at(0, 10, dayOffset: 1), 0, 40)] {
            let label = "saved at \(saveAt.formatted(.iso8601)) with \(hour):\(minute)"
            let nightly = stop("Nightly", hour: 23, minute: 0, end: .after(2 * 3600), repeats: daily)
            var scheduler = makeScheduler([nightly], start: at(9, 0))
            _ = scheduler.tick(now: at(23, 0))
            let moved = moved(nightly, to: hour, minute)
            XCTAssertTrue(scheduler.saveHardStop(moved, isNew: false, now: saveAt) == ([], []), label)
            XCTAssertEqual(scheduler.snapshot.activeHardStop?.merged, [], label)
            XCTAssertEqual(scheduler.snapshot.activeHardStop?.endsAt, at(1, 0, dayOffset: 1), label)
            let wednesday = at(hour, minute, dayOffset: 2)
            XCTAssertEqual(nextHardStop(of: nightly.id, in: scheduler, after: saveAt)?.start, wednesday, label)

            let events = run(&scheduler, from: saveAt, through: wednesday)
            XCTAssertEqual(events.map(\.0), [at(1, 0, dayOffset: 1), wednesday.addingTimeInterval(-10 * 60), wednesday], label)
            XCTAssertEqual(events.map(\.1), [
                .hardStopEnded(id: nightly.id, reason: .ended),
                warning(nightly, hour, minute, dayOffset: 2),
                .hardStopStarted(id: nightly.id, endsAt: wednesday.addingTimeInterval(2 * 3600)),
            ], label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.startedAt), [at(23, 0)], label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.endedAt), [at(1, 0, dayOffset: 1)], label)
        }
    }

    func testARepeatingStopJoinedToTheRunningOneAndEditedAfterMidnightNeverJoinsItAgain() {
        // Long runs every day from 23:00 to 03:00, and Walk (every day 23:30 to 23:45) joins it. At 00:10 on Tuesday Walk is
        // moved to 01:00, inside Long's run.
        let long = stop("Long", hour: 23, minute: 0, end: .after(4 * 3600), repeats: daily, escapeHatch: .extend(minutes: 10, times: 1))
        let walk = stop("Walk", hour: 23, minute: 30, end: .after(15 * 60), repeats: daily, escapeHatch: .dismissEarly)
        var scheduler = makeScheduler([long, walk], start: at(9, 0))
        _ = scheduler.tick(now: at(23, 0))
        _ = scheduler.tick(now: at(23, 30))
        let running = scheduler.snapshot.activeHardStop
        XCTAssertEqual(running?.merged.map(\.id), [walk.id])
        XCTAssertTrue(scheduler.saveHardStop(moved(walk, to: 1, 0), isNew: false, now: at(0, 10, dayOffset: 1)) == ([], []))

        // Long keeps its end, escape hatch, and parts, and Walk is recorded once; it next runs on Wednesday at 01:00.
        var events = run(&scheduler, from: at(0, 10, dayOffset: 1), through: at(2, 59, dayOffset: 1))
        XCTAssertEqual(events.map(\.1), [])
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.merged, running?.merged)
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.endsAt, at(3, 0, dayOffset: 1))
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.escapeHatch, .extend(minutes: 10, times: 1))
        XCTAssertNil(scheduler.snapshot.activeHardStop?.escapeHatchOwner)
        events = run(&scheduler, from: at(2, 59, dayOffset: 1), through: at(4, 0, dayOffset: 1))
        XCTAssertEqual(events.map(\.1), [.hardStopEnded(id: long.id, reason: .ended)])
        XCTAssertEqual(hardStopRecords(scheduler).map(\.startedAt), [at(23, 0), at(23, 30)])
        XCTAssertEqual(hardStopRecords(scheduler).map(\.endedAt), [at(3, 0, dayOffset: 1), at(23, 45)])
        XCTAssertEqual(nextHardStop(of: walk.id, in: scheduler, after: at(4, 0, dayOffset: 1))?.start, at(1, 0, dayOffset: 2))
    }

    func testARepeatingStopWaitingForACallEditedAfterMidnightNeverRunsTwice() {
        // Nightly (every day 23:00 for 2 hours) waits for the call that is running at 23:00 on Monday, so its occurrence ends
        // at 01:00 on Tuesday. At 00:10 it is moved to 00:40; the call ends at 00:50, or after 01:00, at 01:30.
        let nightly = stop("Nightly", hour: 23, minute: 0, end: .after(2 * 3600), repeats: daily, duringCalls: .waitForCallToEnd)
        let cases: [(callEnds: Date, expected: [(Date, BreakScheduler.Event)], records: [HardStopEndReason])] = [
            (at(0, 50, dayOffset: 1), [(at(0, 50, dayOffset: 1), .hardStopStarted(id: nightly.id, endsAt: at(1, 0, dayOffset: 1))),
                                       (at(1, 0, dayOffset: 1), .hardStopEnded(id: nightly.id, reason: .ended))], [.ended]),
            (at(1, 30, dayOffset: 1), [(at(1, 0, dayOffset: 1), .hardStopEnded(id: nightly.id, reason: .missed))], [.missed]),
        ]
        for item in cases {
            let label = "call until \(item.callEnds.formatted(.iso8601))"
            var scheduler = makeScheduler([nightly], start: at(9, 0))
            _ = scheduler.tick(now: at(23, 0), inputs: .init(signals: [.meeting]))
            XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall, [nightly.id.uuidString: key(23, 0)], label)
            XCTAssertTrue(scheduler.saveHardStop(moved(nightly, to: 0, 40), isNew: false, now: at(0, 10, dayOffset: 1)) == ([], []), label)

            // Tuesday's 00:40 neither waits, warns, joins, nor starts after Monday's occurrence; Wednesday's runs.
            let events = run(&scheduler, from: at(0, 10, dayOffset: 1), through: at(3, 0, dayOffset: 1)) {
                $0 < item.callEnds ? .init(signals: [.meeting]) : .init()
            }
            XCTAssertEqual(events.map(\.0), item.expected.map(\.0), label)
            XCTAssertEqual(events.map(\.1), item.expected.map(\.1), label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.hardStopEndReason), item.records, label)
            XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall, [:], label)
            XCTAssertEqual(nextHardStop(of: nightly.id, in: scheduler, after: at(3, 0, dayOffset: 1))?.start, at(0, 40, dayOffset: 2), label)
        }
    }

    func testAStopWithoutAnEndEditedToATimeThatHasPassedNeverJoinsItRetroactively() throws {
        // Evening runs from Monday to Wednesday from 17:00 until dismissed. At 10:00 on Tuesday, while Monday's still runs, it
        // is moved to 09:00: Tuesday's 09:00 had already started, so it does not join; Wednesday's, which starts after the
        // save, does.
        let evening = stop("Evening", hour: 17, minute: 0, end: .untilDismissed, repeats: .weekdays([2, 3, 4]), escapeHatch: .dismissEarly)
        var scheduler = makeScheduler([evening], start: at(9, 0))
        _ = scheduler.tick(now: at(17, 0))
        _ = scheduler.tick(now: at(9, 59, dayOffset: 1))
        XCTAssertTrue(scheduler.saveHardStop(moved(evening, to: 9, 0), isNew: false, now: at(10, 0, dayOffset: 1)) == ([], []))
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.merged, [])

        // It holds after a relaunch too.
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONEncoder().encode(scheduler.snapshot))
        scheduler = BreakScheduler(settings: scheduler.settings, snapshot: snapshot, records: scheduler.records, calendar: calendar)
        scheduler.reconcileRestoredState(now: at(10, 0, dayOffset: 1))
        XCTAssertEqual(scheduler.tick(now: at(10, 0, 1, dayOffset: 1)), [])
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.merged, [])
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.endsAt, nil)

        _ = scheduler.tick(now: at(9, 0, dayOffset: 2))
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.merged.map(\.occurrenceKey), [key(9, 0, dayOffset: 2)])
        XCTAssertEqual(scheduler.dismissHardStop(now: at(9, 30, dayOffset: 2)), [.hardStopEnded(id: evening.id, reason: .dismissed)])
        XCTAssertEqual(hardStopRecords(scheduler).map(\.startedAt), [at(17, 0), at(9, 0, dayOffset: 2)])
    }

    func testAnEditSavedAfterTheEditedStopEndedIsJudgedOnlyAgainstTheOccurrencesThatRan() throws {
        // Lunch runs on Mondays from 12:30 to 13:00. At 12:31 it is moved to 15:00, so today's 15:00 is superseded. At 13:10,
        // once it has ended, it is saved again.
        let lunch = stop(escapeHatch: .none)
        func ended() -> BreakScheduler {
            var scheduler = makeScheduler([lunch], start: at(9, 0))
            _ = scheduler.tick(now: at(12, 30))
            XCTAssertTrue(scheduler.saveHardStop(moved(lunch, to: 15, 0), isNew: false, now: at(12, 31)) == ([], []))
            XCTAssertEqual(run(&scheduler, from: at(12, 31), through: at(13, 10)).map(\.1), [.hardStopEnded(id: lunch.id, reason: .ended)])
            XCTAssertEqual(scheduler.nextHardStop(after: at(13, 10))?.start, at(15, 0, dayOffset: 7))
            return scheduler
        }

        // Moved to 14:00, or made a one-off today at 14:00: it is listed, warned about, shown as next, and starts at 14:00.
        for oneOff in [false, true] {
            let label = oneOff ? "one-off" : "weekly"
            var scheduler = ended()
            var second = moved(lunch, to: 14, 0)
            if oneOff { second.repeats = today }
            XCTAssertTrue(scheduler.saveHardStop(second, isNew: false, now: at(13, 10)) == ([], []), label)
            XCTAssertEqual(scheduler.nextHardStop(after: at(13, 10))?.start, at(14, 0), label)
            let events = run(&scheduler, from: at(13, 10), through: at(23, 59))
            XCTAssertEqual(events.map(\.0), [at(13, 50), at(14, 0), at(14, 30)], label)
            XCTAssertEqual(events.map(\.1), [
                warning(lunch, 14, 0), .hardStopStarted(id: lunch.id, endsAt: at(14, 30)), .hardStopEnded(id: lunch.id, reason: .ended),
            ], label)
            XCTAssertEqual(hardStopRecords(scheduler).map(\.startedAt), [at(12, 30), at(14, 0)], label)
            XCTAssertEqual(scheduler.settings.hardStops, oneOff ? [] : [second], label)
        }

        // Renamed, it keeps 15:00, and the edit still applies from next Monday, also after a relaunch.
        var scheduler = ended()
        var renamed = moved(lunch, to: 15, 0)
        renamed.name = "Late lunch"
        XCTAssertTrue(scheduler.saveHardStop(renamed, isNew: false, now: at(13, 10)) == ([], []))
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONEncoder().encode(scheduler.snapshot))
        scheduler = BreakScheduler(settings: scheduler.settings, snapshot: snapshot, records: scheduler.records, calendar: calendar)
        scheduler.reconcileRestoredState(now: at(13, 10))
        XCTAssertEqual(scheduler.nextHardStop(after: at(13, 10))?.start, at(15, 0, dayOffset: 7))
        XCTAssertEqual(run(&scheduler, from: at(13, 10), through: at(23, 59)).map(\.1), [])
        XCTAssertEqual(hardStopRecords(scheduler).count, 1)
    }

    func testTheInProgressNoteSaysWhatAnEditDoes() {
        let lunch = stop(repeats: today)
        let weekly = stop("Weekly", hour: 16)
        var scheduler = makeScheduler([lunch, weekly])
        XCTAssertNil(scheduler.hardStopInProgressNote(saving: lunch, now: at(12, 29)))
        _ = scheduler.tick(now: at(12, 30))
        XCTAssertNil(scheduler.hardStopInProgressNote(saving: weekly, now: at(12, 31)))
        XCTAssertEqual(scheduler.hardStopInProgressNote(saving: lunch, now: at(12, 31)), HardStopText.inProgress)
        XCTAssertEqual(scheduler.hardStopInProgressNote(saving: moved(lunch, to: 13, 0), now: at(12, 31)), HardStopText.inProgress)
        XCTAssertEqual(scheduler.hardStopInProgressNote(saving: moved(lunch, to: 12, 59), now: at(12, 31)), HardStopText.inProgressSuperseded)
        // Nothing changes until it is saved.
        XCTAssertEqual(scheduler.settings.hardStops, [lunch, weekly])
    }

    func testDeletingAStopDecidesOnTheClockItsConfirmationUses() {
        // Long runs 12:30 to 13:30; Walk starts inside it at 12:45, and the last tick ran at 12:44:59. The
        // confirmation (`runningHardStop`) and the delete use the same clock, so they agree on either side of 12:45.
        let long = stop("Long", end: .after(60 * 60))
        let walk = stop("Walk", hour: 12, minute: 45)
        var scheduler = makeScheduler([long, walk], start: at(9, 0))
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.tick(now: at(12, 44, 59))

        var before = scheduler
        XCTAssertNil(before.runningHardStop(containing: walk.id, now: at(12, 44, 59)))
        XCTAssertEqual(before.deleteHardStop(id: walk.id, now: at(12, 44, 59)), [])
        XCTAssertEqual(before.snapshot.activeHardStop?.id, long.id)
        XCTAssertEqual(before.snapshot.activeHardStop?.endsAt, at(13, 30))
        XCTAssertEqual(before.records.compactMap(\.hardStopEndReason), [])

        var after = scheduler
        XCTAssertEqual(after.runningHardStop(containing: walk.id, now: at(12, 45))?.id, long.id)
        XCTAssertEqual(after.deleteHardStop(id: walk.id, now: at(12, 45)), [.hardStopEnded(id: long.id, reason: .dismissed)])
        XCTAssertNil(after.snapshot.activeHardStop)
        XCTAssertEqual(after.records.compactMap(\.hardStopEndReason), [.dismissed, .dismissed])
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
