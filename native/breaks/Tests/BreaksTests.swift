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
}
