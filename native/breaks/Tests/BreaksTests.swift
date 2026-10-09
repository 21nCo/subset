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
    }

    func testScreenScorePenalizesSkipsAndSnoozes() {
        let now = Date()
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
        let stats = BreakMath.stats(records: [skipped], snapshot: snapshot, now: now)
        XCTAssertEqual(stats.skippedBreaks, 1)
        XCTAssertEqual(stats.snoozes, 2)
        XCTAssertLessThan(stats.screenScore, 100)
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
