import XCTest
#if os(iOS)
@testable import Breaks
#endif

final class BreaksTests: XCTestCase {
    func testOfficeHoursSupportsRegularAndOvernightWindows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10)))
        let monday = calendar.component(.weekday, from: day)
        let morning = try XCTUnwrap(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day))
        let late = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: day))

        let regular = OfficeHours(isEnabled: true, startHour: 8, startMinute: 0, endHour: 18, endMinute: 0, weekdays: [monday])
        XCTAssertTrue(regular.contains(morning, calendar: calendar))
        XCTAssertFalse(regular.contains(late, calendar: calendar))

        let overnight = OfficeHours(isEnabled: true, startHour: 22, startMinute: 0, endHour: 6, endMinute: 0, weekdays: [monday])
        XCTAssertTrue(overnight.contains(late, calendar: calendar))
        XCTAssertFalse(overnight.contains(morning, calendar: calendar))
        // Monday's overnight window continues into Tuesday morning, even though Tuesday is not selected.
        let tuesdayEarly = try XCTUnwrap(calendar.date(byAdding: .hour, value: 4, to: late))
        XCTAssertTrue(overnight.contains(tuesdayEarly, calendar: calendar))
        // Monday before 06:00 belongs to Sunday's window, which is not selected.
        let mondayEarly = try XCTUnwrap(calendar.date(bySettingHour: 3, minute: 0, second: 0, of: day))
        XCTAssertFalse(overnight.contains(mondayEarly, calendar: calendar))
    }

    func testScreenScorePenalizesSkipsAndSnoozes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12)))
        let skipped = BreakRecord(
            startedAt: now.addingTimeInterval(-300),
            endedAt: now.addingTimeInterval(-300),
            plannedDuration: 20,
            kind: .short,
            completed: false,
            skipped: true
        )
        var snapshot = EngineSnapshot(focusStartedAt: now.addingTimeInterval(-600), nextBreakAt: now.addingTimeInterval(600))
        snapshot.snoozesUsedToday = 2
        let stats = BreakMath.stats(records: [skipped], snapshot: snapshot, now: now, calendar: calendar)
        XCTAssertEqual(stats.skippedBreaks, 1)
        XCTAssertEqual(stats.snoozes, 2)
        XCTAssertLessThan(stats.screenScore, 100)
    }

    func testStretchesMeasureFocusBeforeEachBreakNotTimeSinceMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 15, minute: 10)))
        func taken(at minutesAgo: TimeInterval, after focus: TimeInterval) -> BreakRecord {
            let start = now.addingTimeInterval(-minutesAgo * 60)
            return BreakRecord(startedAt: start, endedAt: start.addingTimeInterval(20), plannedDuration: 20, kind: .short, completed: true, skipped: false, focusDuration: focus * 60)
        }
        let records = [taken(at: 50, after: 20), taken(at: 30, after: 20), taken(at: 10, after: 20)]
        let snapshot = EngineSnapshot(focusStartedAt: now.addingTimeInterval(-10 * 60), nextBreakAt: now.addingTimeInterval(10 * 60))
        let stats = BreakMath.stats(records: records, snapshot: snapshot, now: now, calendar: calendar)
        XCTAssertEqual(stats.longestStretch, 20 * 60)
        XCTAssertEqual(stats.typicalStretch, 20 * 60)
        XCTAssertEqual(stats.focusTime, 70 * 60)
        XCTAssertEqual(stats.screenScore, 100)
    }

    func testClockDurationShowsHours() {
        XCTAssertEqual(TimeInterval(90).clockDuration, "01:30")
        XCTAssertEqual(TimeInterval(2 * 3600 + 5).clockDuration, "2:00:05")
    }

    func testRepositoryRoundTrip() throws {
        let suiteName = "BreaksTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let repository = BreakRepository(defaults: defaults)
        var settings = BreakSettings()
        settings.workInterval = 25 * 60
        let snapshot = EngineSnapshot(nextBreakAt: Date().addingTimeInterval(25 * 60), snoozesUsedToday: 3)
        let record = BreakRecord(startedAt: .now, endedAt: .now, plannedDuration: 20, kind: .short, completed: true, skipped: false)
        repository.save(settings: settings, snapshot: snapshot, records: [record])

        XCTAssertEqual(repository.loadSettings().workInterval, 25 * 60)
        XCTAssertEqual(repository.loadSnapshot(settings: settings).snoozesUsedToday, 3)
        XCTAssertEqual(repository.loadRecords().count, 1)
    }

    func testHardStopHistorySurvivesAnEarlierBuildSavingItsHistory() throws {
        let suiteName = "BreaksTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = BreakRepository(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_786_000_000)
        func record(_ kind: BreakKind, _ minute: Double) -> BreakRecord {
            BreakRecord(startedAt: start + minute * 60, endedAt: start + minute * 60 + 20, plannedDuration: 20, kind: kind, completed: true, skipped: false)
        }
        let records = [record(.short, 0), record(.hardStop, 10), record(.long, 20)]
        repository.save(settings: BreakSettings(), snapshot: EngineSnapshot(), records: records)

        // An earlier build knows only these kinds and decodes the whole history array at once.
        struct EarlierRecord: Codable {
            enum Kind: String, Codable { case short, long, planned, manual }
            var id: UUID
            var kind: Kind
        }
        let legacy = try JSONDecoder().decode([EarlierRecord].self, from: XCTUnwrap(defaults.data(forKey: SharedStore.recordsKey)))
        XCTAssertEqual(legacy.map(\.id), [records[0].id, records[2].id])

        // It saves its own history, with a new break, and does not know the hard-stop key.
        let newer = record(.short, 30)
        defaults.set(try JSONEncoder().encode([records[0], records[2], newer]), forKey: SharedStore.recordsKey)
        XCTAssertEqual(repository.loadRecords().map(\.id), [records[0].id, records[1].id, records[2].id, newer.id])
    }

    // MARK: - Hard stops

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testNewHardStopUsesProductDefaults() {
        let stop = HardStop(name: "Evening", hour: 18, minute: 0)
        XCTAssertTrue(stop.isEnabled)
        XCTAssertEqual(stop.escapeHatch, .extend(minutes: 15, times: 1))
        XCTAssertEqual(stop.warningMinutes, [10, 2])
        XCTAssertEqual(stop.duringCalls, .waitForCallToEnd)
        XCTAssertEqual(stop.repeats, .weekdays([2, 3, 4, 5, 6]))
        XCTAssertEqual(stop.end, .after(30 * 60))
        XCTAssertEqual(BreakSettings().hardStops, [])
    }

    func testHardStopEndAtOrBeforeStartFallsOnNextDay() throws {
        let start = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 22)))
        var stop = HardStop(name: "Night", hour: 22, minute: 0, end: .at(hour: 6, minute: 0))
        XCTAssertEqual(stop.end(forStart: start, calendar: utc), start.addingTimeInterval(8 * 3600))
        stop.end = .at(hour: 22, minute: 0)
        XCTAssertEqual(stop.end(forStart: start, calendar: utc), start.addingTimeInterval(24 * 3600))
        stop.end = .at(hour: 23, minute: 15)
        XCTAssertEqual(stop.end(forStart: start, calendar: utc), start.addingTimeInterval(75 * 60))
    }

    func testSettingsAndSnapshotsSavedBeforeHardStopsStillDecode() throws {
        var settings = BreakSettings()
        settings.workInterval = 1500
        var legacySettings = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacySettings.removeValue(forKey: "hardStops")
        let decodedSettings = try JSONDecoder().decode(BreakSettings.self, from: JSONSerialization.data(withJSONObject: legacySettings))
        XCTAssertEqual(decodedSettings.workInterval, 1500)
        XCTAssertEqual(decodedSettings.hardStops, [])

        let snapshot = EngineSnapshot(phase: .paused, nextBreakAt: Date(timeIntervalSince1970: 1_000_000), snoozesUsedToday: 2, pauseReason: .manual)
        var legacySnapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for key in ["hardStopWarnings", "handledHardStops", "hardStopsWaitingForCall", "hardStopWaitingRules", "supersededHardStops", "hardStopsEditedInProgress"] {
            XCTAssertNotNil(legacySnapshot.removeValue(forKey: key), key)
        }
        XCTAssertNil(legacySnapshot["activeHardStop"])
        let decodedSnapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONSerialization.data(withJSONObject: legacySnapshot))
        XCTAssertEqual(decodedSnapshot, snapshot)
        XCTAssertNil(decodedSnapshot.activeHardStop)
        XCTAssertTrue(decodedSnapshot.hardStopWarnings.isEmpty)
        XCTAssertTrue(decodedSnapshot.handledHardStops.isEmpty)
    }

    func testHardStopSettingsRoundTripEveryCase() throws {
        let stops = [
            HardStop(name: "A", hour: 9, minute: 15, end: .at(hour: 9, minute: 45), repeats: .once(DateComponents(year: 2027, month: 1, day: 15)), warningMinutes: [], escapeHatch: .none, duringCalls: .startAnyway),
            HardStop(name: "B", hour: 22, minute: 0, end: .untilDismissed, escapeHatch: .dismissEarly),
            HardStop(name: "C", hour: 17, minute: 30)
        ]
        var settings = BreakSettings()
        settings.hardStops = stops
        let decoded = try JSONDecoder().decode(BreakSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.hardStops, stops)
    }

    func testHardStopValidationReportsFieldErrors() throws {
        let now = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12)))
        var settings = BreakSettings()
        let valid = HardStop(name: "Evening", hour: 18, minute: 0)
        settings.hardStops = [valid, HardStop(name: "Tomorrow", hour: 9, minute: 0, repeats: .once(on: now.addingTimeInterval(24 * 3600), calendar: utc))]
        XCTAssertEqual(settings.hardStopErrors(now: now, calendar: utc), [])

        func errors(_ change: (inout HardStop) -> Void) -> [HardStopFieldError.Field] {
            var stop = valid
            change(&stop)
            var edited = BreakSettings()
            edited.hardStops = [stop]
            let found = edited.hardStopErrors(now: now, calendar: utc)
            XCTAssertTrue(found.allSatisfy { $0.stopID == stop.id && !$0.message.isEmpty })
            return found.map(\.field)
        }
        XCTAssertEqual(errors { $0.name = "  " }, [.name])
        XCTAssertEqual(errors { $0.hour = 24 }, [.start])
        XCTAssertEqual(errors { $0.minute = -1 }, [.start])
        XCTAssertEqual(errors { $0.end = .at(hour: 7, minute: 60) }, [.end])
        XCTAssertEqual(errors { $0.end = .after(30) }, [.end])
        XCTAssertEqual(errors { $0.end = .after(16 * 3600 + 60) }, [.end])
        XCTAssertEqual(errors { $0.end = .after(16 * 3600) }, [])
        XCTAssertEqual(errors { $0.repeats = .weekdays([]) }, [.repeats])
        XCTAssertEqual(errors { $0.repeats = .weekdays([0, 2]) }, [.repeats])
        // A one-off stop earlier today has passed; one later today has not.
        XCTAssertEqual(errors { $0.hour = 9; $0.repeats = .once(on: now, calendar: utc) }, [.repeats])
        XCTAssertEqual(errors { $0.repeats = .once(on: now, calendar: utc) }, [])
        XCTAssertEqual(errors { $0.repeats = .once(DateComponents(year: 2026, month: 8)) }, [.repeats])
        XCTAssertEqual(errors { $0.repeats = .once(DateComponents(year: 2027, month: 2, day: 30)) }, [.repeats])
        // A malformed time is reported, not evaluated.
        XCTAssertEqual(errors { $0.end = .at(hour: Int.max, minute: 0); $0.repeats = .once(on: now.addingTimeInterval(86400), calendar: utc) }, [.end])
        XCTAssertEqual(errors { $0.hour = Int.min; $0.repeats = .once(on: now.addingTimeInterval(86400), calendar: utc) }, [.start])
        XCTAssertEqual(errors { $0.warningMinutes = [1, 2, 3, 4, 5, 6] }, [.warningMinutes])
        XCTAssertEqual(errors { $0.warningMinutes = [0] }, [.warningMinutes])
        XCTAssertEqual(errors { $0.warningMinutes = [121] }, [.warningMinutes])
        XCTAssertEqual(errors { $0.warningMinutes = [] }, [])
        XCTAssertEqual(errors { $0.escapeHatch = .extend(minutes: 4, times: 1) }, [.escapeHatch])
        XCTAssertEqual(errors { $0.escapeHatch = .extend(minutes: 15, times: 6) }, [.escapeHatch])
        XCTAssertEqual(errors { $0.escapeHatch = .extend(minutes: 60, times: 5) }, [])

        settings.hardStops = (0...HardStop.maximumCount).map { HardStop(name: "Stop \($0)", hour: 18, minute: 0) }
        let tooMany = settings.hardStopErrors(now: now, calendar: utc)
        XCTAssertEqual(tooMany.map(\.field), [.list])
        XCTAssertNil(tooMany.first?.stopID)
    }
}
