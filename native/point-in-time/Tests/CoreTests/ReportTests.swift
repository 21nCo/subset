import Foundation
import Testing
@testable import PointInTimeCore

/// A Monday-first Gregorian calendar in `zone`.
private func calendar(_ zone: String = "America/New_York") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.firstWeekday = 2
    return calendar
}

private func date(_ calendar: Calendar, _ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// A block at `start` labeled `label` by the model, or by the user with `corrected`; nil leaves it pending (or `failed`).
private func block(_ start: Date, _ label: BlockLabel?, corrected: Bool = false, failed: Bool = false, active: Double = 180,
                   excluded: Double = 0, app: String = "com.example.editor", host: String? = nil) -> Block {
    let apps = active > 0 ? [AppTime(bundleID: app, appName: "App \(app)", seconds: active)] : []
    let labeling = label.map { BlockLabeling(state: corrected ? .corrected : .classified, label: $0, provider: corrected ? "user" : "openrouter") }
        ?? BlockLabeling(state: failed ? .failed : .pending)
    return Block(start: start, activeSeconds: active, excludedSeconds: excluded, apps: apps, dominantBundleID: apps.first?.bundleID,
                 dominantAppName: apps.first?.appName, dominantTitle: nil,
                 dominantURL: host.map { RedactedURL(scheme: "https", host: $0, path: "/") }, labeling: labeling)
}

/// `count` consecutive blocks from `start`, all labeled `label`.
private func run(_ start: Date, _ count: Int, _ label: BlockLabel?, active: Double = 180) -> [Block] {
    (0..<count).map { block(start.addingTimeInterval(Double($0) * Block.length), label, active: active) }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pit-reports-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct BlockTimeTests {
    private let start = date(calendar(), 20, 9)

    @Test func modelLabelsCoverRecordedAppTimeAndLeaveExcludedTimeExcluded() {
        let seconds = block(start, .focus, active: 120, excluded: 30).categorySeconds
        #expect(seconds.focus == 120)
        #expect(seconds.excluded == 30)
        #expect(seconds.recorded == 150)
    }

    @Test func aCorrectionCoversTheWholeBlockIncludingExcludedTime() {
        let seconds = block(start, .neutral, corrected: true, active: 120, excluded: 30).categorySeconds
        #expect(seconds.neutral == 150)
        #expect(seconds.excluded == 0)
        // A block holding only excluded time is drawn as excluded until the user labels it.
        #expect(block(start, nil, active: 0, excluded: 90).category == .excluded)
        #expect(block(start, .drift, corrected: true, active: 0, excluded: 90).category == .drift)
    }

    @Test func pendingAndFailedBlocksAreUnclassifiedEvenWithStaleLabelColumns() {
        var stale = block(start, nil)
        stale.labeling.label = .focus  // The store never returns this, but a pending label must not count.
        #expect(stale.categorySeconds.unclassified == 180)
        #expect(stale.category == .unclassified)
        #expect(block(start, nil, failed: true).categorySeconds.unclassified == 180)
    }
}

@Suite struct DayReportTests {
    private let cal = calendar()

    @Test func focusShareDividesByClassifiedTimeOnly() {
        let blocks = run(date(cal, 20, 9), 4, .focus) + run(date(cal, 20, 10), 2, .drift) + run(date(cal, 20, 11), 2, .neutral)
            + run(date(cal, 20, 12), 10, nil) + [block(date(cal, 20, 13), nil, active: 0, excluded: 180)]
        let report = DayReport(day: date(cal, 20, 15), blocks: blocks, calendar: cal)
        #expect(report.totals.focus == 720)
        #expect(report.totals.unclassified == 1_800)
        #expect(report.totals.excluded == 180)
        #expect(report.totals.focusShare == 0.5)
        #expect(report.pendingCount == 10)  // The excluded-only block is never sent, so it is not waiting.
        #expect(ReportText.totals(report.totals)
                == "Focus 12 min, Neutral 6 min, Drift 6 min, Unclassified 30 min, Excluded 3 min. Focus is 50% of classified time.")
    }

    @Test func anAllUnclassifiedDayHasNoFocusShare() {
        let report = DayReport(day: date(cal, 20, 9), blocks: run(date(cal, 20, 9), 5, nil) + [block(date(cal, 20, 10), nil, failed: true)],
                               calendar: cal)
        #expect(report.totals.unclassified == 1_080)
        #expect(report.totals.focusShare == nil)
        #expect(report.failedCount == 1)
        #expect(report.pendingCount == 5)
        #expect(ReportText.totals(report.totals) == "Unclassified 18 min. Nothing is classified yet.")
        #expect(ReportText.totals(DayReport(day: date(cal, 20, 9), blocks: [], calendar: cal).totals) == "No activity recorded.")
    }

    @Test func appsAndSitesAreTotaledLongestFirst() {
        var mixed = block(date(cal, 20, 9), .focus, host: "docs.example.com")
        mixed.apps = [AppTime(bundleID: "com.example.editor", appName: "Editor", seconds: 100), AppTime(bundleID: "com.example.chat", appName: "Chat", seconds: 50)]
        mixed.activeSeconds = 150
        let report = DayReport(day: date(cal, 20, 9), blocks: [
            mixed,
            block(date(cal, 20, 9, 3), .drift, app: "com.example.chat", host: "news.example.com"),
            block(date(cal, 20, 9, 6), .focus, app: "com.example.chat", host: "docs.example.com")
        ], calendar: cal)
        #expect(report.apps.map(\.id) == ["com.example.chat", "com.example.editor"])
        #expect(report.apps.map(\.seconds) == [410, 100])
        // A site gets its block's main-app time, not the other apps' time in that block.
        #expect(report.hosts.map(\.id) == ["docs.example.com", "news.example.com"])
        #expect(report.hosts.map(\.seconds) == [280, 180])
    }

    @Test func idleAndExcludedGapsEndSpans() {
        let blocks = run(date(cal, 20, 9), 3, .focus)
            // 09:09 holds nothing (idle for the whole block), so the next focus starts a new span.
            + run(date(cal, 20, 9, 12), 2, .focus, active: 60)
            + [block(date(cal, 20, 9, 18), nil, active: 0, excluded: 180)]
            + run(date(cal, 20, 9, 21), 1, .focus)
        let spans = DayReport(day: date(cal, 20, 9), blocks: blocks, calendar: cal).spans
        #expect(spans.map(\.category) == [.focus, .focus, .excluded, .focus])
        #expect(spans.map(\.blockCount) == [3, 2, 1, 1])
        #expect(spans[1].seconds == 120)  // Idle inside a block is not in its total.
        #expect(spans[1].duration == 360)
    }

    @Test func rhythmSumsHalfHoursOfClockTime() {
        let blocks = run(date(cal, 20, 9), 10, .focus) + run(date(cal, 20, 9, 30), 3, .drift) + run(date(cal, 20, 23, 57), 1, .neutral)
        let rhythm = DayReport(day: date(cal, 20, 9), blocks: blocks, calendar: cal).rhythm
        #expect(rhythm.count == 48)
        #expect(rhythm[18].minuteOfDay == 540)
        #expect(rhythm[18].seconds.focus == 1_800)
        #expect(rhythm[19].seconds.drift == 540)
        #expect(rhythm[47].seconds.neutral == 180)
        #expect(ReportText.rhythm(rhythm) == "Half-hour rhythm: most focus from 09:00 to 09:30 (30 min); most drift from 09:30 to 10:00 (9 min).")
    }
}

@Suite struct MidnightTests {
    private let cal = calendar()

    @Test func aSegmentAcrossMidnightCountsOnEachDayItCovers() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        let start = date(cal, 20, 23, 51)
        try store.save(Segment(start: start, end: start.addingTimeInterval(18 * 60), excluded: false, bundleID: "com.example.editor",
                               appName: "Editor", windowTitle: "Spec", url: nil))
        let blocks = try store.blocks(from: date(cal, 19, 0), to: date(cal, 22, 0))
        try store.applyClassifications(blocks.map { BlockClassification(blockStart: $0.start, revision: $0.revision, label: .focus, reason: "Spec", confidence: 0.9) },
                                       rejected: [], provider: "openrouter", model: "m", at: date(cal, 21, 1))
        let labeled = try store.blocks(from: date(cal, 19, 0), to: date(cal, 22, 0))
        let week = WeekReport(containing: date(cal, 20, 12), blocks: labeled, calendar: cal)
        let tuesday = week.days[1], wednesday = week.days[2]
        #expect(tuesday.totals.focus == 540)
        #expect(wednesday.totals.focus == 540)
        // The day calendar splits at midnight; the weekly focus run does not.
        #expect(tuesday.spans.last?.end == date(cal, 21, 0))
        #expect(wednesday.spans.first?.start == date(cal, 21, 0))
        #expect(week.profile.longestFocusRun?.start == start)
        #expect(week.profile.longestFocusRun?.duration == 1_080)
        // The run starts on Tuesday; continuing past midnight does not make 00:00 a Wednesday focus start.
        #expect(week.profile.focusDays == 1)
        #expect(week.profile.typicalFocusStart == 23 * 60 + 51)
        #expect(week.profile.startSpread == nil)
    }

    @Test func aDayWithAContinuedRunAndItsOwnLaterStartCountsTheLaterStart() {
        let blocks = run(date(cal, 20, 23, 51), 6, .focus) + run(date(cal, 21, 10), 2, .focus)
        let profile = WeekReport(containing: date(cal, 20, 12), blocks: blocks, calendar: cal).profile
        #expect(profile.focusDays == 2)
        #expect(profile.typicalFocusStart == (10 * 60 + 23 * 60 + 51) / 2)
        #expect(profile.longestFocusRun?.start == date(cal, 20, 23, 51))
    }

    @Test func aRunContinuingIntoTheWeekFromTheSundayBeforeIsNotAMondayStart() {
        // The window reads the block that ends as the week starts, so Monday's 00:00 is known to continue Sunday's run.
        let blocks = run(date(cal, 18, 23, 57), 3, .focus) + run(date(cal, 19, 9), 2, .focus)
        let profile = WeekReport(containing: date(cal, 19, 12), blocks: blocks, calendar: cal).profile
        #expect(profile.focusDays == 1)
        #expect(profile.typicalFocusStart == 540)
        // Only the week's part of that run is in it.
        #expect(profile.longestFocusRun?.start == date(cal, 19, 0))
        #expect(profile.longestFocusRun?.duration == 360)
        #expect(WeekReport(containing: date(cal, 19, 12), blocks: blocks, calendar: cal).totals.focus == 4 * 180)
    }

    @Test func aWeekWhoseOnlyFocusContinuedFromBeforeItSaysSoInsteadOfNoFocus() {
        let blocks = run(date(cal, 18, 23, 57), 3, .focus)
        let profile = WeekReport(containing: date(cal, 19, 12), blocks: blocks, calendar: cal).profile
        #expect(profile.focusSeconds == 360 && profile.typicalFocusStart == nil && profile.focusDays == 0)
        #expect(profile.longestFocusRun?.duration == 360)
        let summary = ReportText.profile(profile)
        #expect(summary.hasPrefix("Focus continued from before the week, with no new focus start this week;"))
        #expect(!summary.contains("No focus"))
    }

    @Test func aDriftContinuingFromBeforeTheWeekIsNotAShortDrift() {
        // Sunday 23:00 to Monday 00:03 is one long drift with three minutes in the week; Monday 10:00 to 10:03 is short.
        let blocks = run(date(cal, 18, 23), 21, .drift) + run(date(cal, 19, 9, 57), 1, .focus) + run(date(cal, 19, 10), 1, .drift)
            + run(date(cal, 19, 10, 3), 1, .focus)
        let profile = WeekReport(containing: date(cal, 19, 12), blocks: blocks, calendar: cal).profile
        #expect(profile.shortDrifts == 1)
        // Without the blocks before the week the boundary drift would look short too.
        let weekOnly = WeekReport(containing: date(cal, 19, 12), blocks: blocks.filter { $0.start >= date(cal, 19, 0) }, calendar: cal)
        #expect(weekOnly.profile.shortDrifts == 2)
    }
}

@Suite struct DaylightSavingTests {
    private let cal = calendar()

    @Test func dayLengthsFollowTheClockChange() {
        // New York: clocks go back on Sunday 1 November 2026 and forward on Sunday 8 March 2026.
        #expect(ReportPeriod.day(containing: date(cal, 1, 12, month: 11), calendar: cal).duration == 25 * 3_600)
        #expect(ReportPeriod.day(containing: date(cal, 8, 12, month: 3), calendar: cal).duration == 23 * 3_600)
        let days = ReportPeriod.days(ofWeekContaining: date(cal, 28, 12), calendar: cal)
        #expect(days.count == 7)
        #expect(days.first?.start == date(cal, 26, 0))
        #expect(days.last?.end == date(cal, 2, 0, month: 11))
        #expect(zip(days, days.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test func theRepeatedHourFallsInTheSameRhythmSlotsAndEveryBlockIsCounted() {
        let dayStart = date(cal, 1, 0, month: 11)
        // 25 hours of focus, one block every three minutes from midnight to midnight.
        let blocks = run(dayStart, 500, .focus)
        let report = DayReport(day: dayStart, blocks: blocks, calendar: cal)
        #expect(report.blocks.count == 500)
        #expect(report.totals.focus == 25 * 3_600)
        // 01:00–02:00 happens twice, so its two half-hour slots hold an hour each.
        #expect(report.rhythm[2].seconds.focus == 3_600)
        #expect(report.rhythm[3].seconds.focus == 3_600)
        #expect(report.rhythm[4].seconds.focus == 1_800)
        let week = WeekReport(containing: dayStart, blocks: blocks, calendar: cal)
        #expect(week.heatmap[6 * 24 + 1].seconds.focus == 7_200)
        #expect(week.days[6].blocks.count == 500)
    }

    @Test func theSkippedHourIsEmpty() {
        let dayStart = date(cal, 8, 0, month: 3)
        let report = DayReport(day: dayStart, blocks: run(dayStart, 460, .drift), calendar: cal)
        #expect(report.totals.drift == 23 * 3_600)
        #expect(report.rhythm[4].seconds.drift == 0)
        #expect(report.rhythm[5].seconds.drift == 0)
        #expect(report.rhythm[6].seconds.drift == 1_800)
    }

    @Test func calendarSpansRunFromTheirStartClockTimeToTheirEndClockTime() {
        // Spring forward: 40 blocks from 01:00 take two hours of elapsed time and end at 04:00 by the clock.
        let spring = date(cal, 8, 0, month: 3)
        let springDay = DayReport(day: spring, blocks: run(date(cal, 8, 1, month: 3), 40, .focus), calendar: cal)
        #expect(springDay.spans.count == 1)
        #expect(ReportPeriod.clockMinutes(of: springDay.spans[0], day: springDay.interval, calendar: cal) == 60...240)
        // Fall back: 80 blocks from the first 01:00 take four hours and end at 04:00 by the clock, after passing
        // 01:00–02:00 twice.
        let fall = date(cal, 1, 0, month: 11)
        let fallDay = DayReport(day: fall, blocks: run(date(cal, 1, 1, month: 11), 80, .focus), calendar: cal)
        #expect(ReportPeriod.clockMinutes(of: fallDay.spans[0], day: fallDay.interval, calendar: cal) == 60...240)
        // A span inside the repeated hour that ends at a lower clock time reaches the latest time it passed, 02:00.
        let repeated = DayReport(day: fall, blocks: run(date(cal, 1, 1, 30, month: 11), 15, .drift), calendar: cal)
        #expect(ReportPeriod.clockMinutes(of: repeated.spans[0], day: repeated.interval, calendar: cal) == 90...120)
        // A span ending at the next midnight ends at 1440, on a 25-hour day too.
        let late = DayReport(day: fall, blocks: run(date(cal, 1, 23, month: 11), 20, .neutral), calendar: cal)
        #expect(ReportPeriod.clockMinutes(of: late.spans[0], day: late.interval, calendar: cal) == 1_380...1_440)
    }

    @Test func spansEndingAtTheFallBackInstantCoverTheFirstPassThroughTheRepeatedHour() {
        // The clocks go back at 02:00 EDT, which is 01:00 EST: a span ending there ends the first pass, at 02:00.
        let fall = date(cal, 1, 0, month: 11)
        let change = cal.timeZone.nextDaylightSavingTimeTransition(after: fall)!
        func minutes(from start: Date, to end: Date) -> ClosedRange<Double> {
            let blocks = run(start, Int(end.timeIntervalSince(start) / Block.length), .focus)
            let day = DayReport(day: fall, blocks: blocks, calendar: cal)
            #expect(day.spans.count == 1)
            return ReportPeriod.clockMinutes(of: day.spans[0], day: day.interval, calendar: cal)
        }
        #expect(minutes(from: fall, to: change) == 0...120)
        #expect(minutes(from: change.addingTimeInterval(-3_600), to: change) == 60...120)
        #expect(minutes(from: change.addingTimeInterval(-1_800), to: change) == 90...120)
        // The second pass starts at the change, at 01:00 again.
        #expect(minutes(from: change, to: change.addingTimeInterval(3_600)) == 60...120)
    }

    @Test func timesInTheRepeatedHourNameTheirPass() {
        let gb = Locale(identifier: "en_GB")
        let fall = date(cal, 1, 0, month: 11)
        let change = cal.timeZone.nextDaylightSavingTimeTransition(after: fall)!
        let firstHour = change.addingTimeInterval(-3_600), secondHour = change
        func time(_ date: Date, asEnd: Bool = false) -> String { ReportText.time(date, calendar: cal, locale: gb, asEnd: asEnd) }
        // Both hours start at 01:00 by the clock, but their labels differ.
        #expect(time(firstHour).hasSuffix("1:00 EDT"))
        #expect(time(secondHour).hasSuffix("1:00 EST"))
        #expect(time(firstHour.addingTimeInterval(1_620)).hasSuffix("1:27 EDT"))
        #expect(time(secondHour.addingTimeInterval(1_620)).hasSuffix("1:27 EST"))
        // The first hour ends at the change, which closes it at 02:00 EDT; the second ends at a plain 02:00.
        #expect(time(change, asEnd: true).hasSuffix("2:00 EDT"))
        #expect(time(change.addingTimeInterval(3_600), asEnd: true).hasSuffix("2:00"))
        #expect(!time(change.addingTimeInterval(3_600), asEnd: true).contains("E"))
        #expect("\(time(firstHour)) to \(time(change, asEnd: true))" != "\(time(secondHour)) to \(time(change.addingTimeInterval(3_600), asEnd: true))")
        // Outside the repeated hour, and on an ordinary day, times carry no zone.
        #expect(!time(fall).contains("E"))
        #expect(!time(change.addingTimeInterval(-3_660)).contains("E"))
        #expect(time(date(cal, 20, 9, 30)).hasSuffix("9:30"))
        #expect(time(date(cal, 20, 9, 30), asEnd: true).hasSuffix("9:30"))
        // The skipped hour on the spring-forward day is never shown, and the times around it carry no zone.
        let spring = date(cal, 8, 0, month: 3)
        let forward = cal.timeZone.nextDaylightSavingTimeTransition(after: spring)!
        #expect(time(forward).hasSuffix("3:00"))
        #expect(time(forward, asEnd: true).hasSuffix("3:00"))
    }

    @Test func clockLabelsNameWallTimesTheDayMayNotHave() {
        // 02:30 does not exist on 8 March in New York, but the label is the wall time itself, not a shifted one.
        // (Whether the hour has a leading zero depends on the system's locale data.)
        #expect(ReportText.clock(150, locale: Locale(identifier: "en_GB")).hasSuffix("2:30"))
        #expect(ReportText.clock(870, locale: Locale(identifier: "en_GB")) == "14:30")
        #expect(ReportText.clock(150, locale: Locale(identifier: "en_US")).hasPrefix("2:30"))
        #expect(ReportText.clock(1_440, locale: Locale(identifier: "en_GB")).hasSuffix("0:00"))
    }

    @Test func focusStartsAreClockTimesAcrossTheChange() {
        // 09:00 every day of the week the clocks go back; measured from a fixed instant they would differ by an hour.
        let blocks = (26...31).flatMap { run(date(cal, $0, 9), 2, .focus) } + run(date(cal, 1, 9, month: 11), 2, .focus)
        let profile = WeekReport(containing: date(cal, 28, 12), blocks: blocks, calendar: cal).profile
        #expect(profile.focusDays == 7)
        #expect(profile.typicalFocusStart == 540)
        #expect(profile.startSpread == 0)
    }
}

@Suite struct WeekReportTests {
    private let cal = calendar()

    @Test func barsHeatmapAndRhythmCoverOnlyTheWeek() {
        let blocks = run(date(cal, 19, 9), 4, .focus) + run(date(cal, 21, 14), 2, .drift) + run(date(cal, 25, 22), 1, .neutral)
            + run(date(cal, 18, 9), 5, .focus) + run(date(cal, 26, 9), 5, .focus)  // Sunday before and Monday after.
        let week = WeekReport(containing: date(cal, 22, 12), blocks: blocks, calendar: cal)
        #expect(week.interval.start == date(cal, 19, 0))
        #expect(week.days.map(\.totals.recorded) == [720, 0, 360, 0, 0, 0, 180])
        #expect(week.totals.recorded == 1_260)
        #expect(week.heatmap.count == 168)
        #expect(week.heatmap[0 * 24 + 9].seconds.focus == 720)
        #expect(week.heatmap[0 * 24 + 9].seconds.focusShare == 1)
        #expect(week.heatmap[2 * 24 + 14].seconds.drift == 360)
        #expect(week.rhythm[18].seconds.focus == 720)
        #expect(week.rhythm[44].seconds.neutral == 180)
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        #expect(ReportText.bars(week.days) { day in names[week.days.firstIndex { $0.interval == day.interval }!] }
                == "Mon: focus 12 min, neutral 0 min, drift 0 min. Wed: focus 0 min, neutral 0 min, drift 6 min. Sun: focus 0 min, neutral 3 min, drift 0 min.")
        #expect(ReportText.heatmap(week.heatmap) { names[$0] } == "Focus in 1 hour of the week; the most on Mon from 09:00 (12 min).")
    }

    @Test func barsSummaryNamesExcludedTimeTheChartLeavesOut() {
        // Tuesday holds only excluded time; Wednesday holds focus and excluded time.
        let blocks = [block(date(cal, 20, 9), nil, active: 0, excluded: 180), block(date(cal, 21, 9), .focus, active: 120, excluded: 60)]
        let week = WeekReport(containing: date(cal, 22, 12), blocks: blocks, calendar: cal)
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        #expect(ReportText.bars(week.days) { day in names[week.days.firstIndex { $0.interval == day.interval }!] }
                == "Tue: focus 0 min, neutral 0 min, drift 0 min, excluded 3 min. Wed: focus 2 min, neutral 0 min, drift 0 min, excluded 1 min.")
    }

    @Test func profileMeasuresStartsRunsShortDriftsAndBalance() {
        let blocks =
            // Monday: focus from 09:00 for 30 min, a 3-min drift, focus again for 9 min.
            run(date(cal, 19, 9), 10, .focus) + run(date(cal, 19, 9, 30), 1, .drift) + run(date(cal, 19, 9, 33), 3, .focus)
            // Tuesday: focus from 10:00; two drift blocks with 6 min of drift (not short) and two with 5 min (short).
            + run(date(cal, 20, 10), 2, .focus) + run(date(cal, 20, 11), 2, .drift) + run(date(cal, 20, 12), 2, .drift, active: 150)
            // Thursday: focus from 08:00; Friday and later: none.
            + run(date(cal, 22, 8), 1, .focus)
        let profile = WeekReport(containing: date(cal, 22, 12), blocks: blocks, calendar: cal).profile
        #expect(profile.focusDays == 3)
        #expect(profile.typicalFocusStart == 540)  // Median of 08:00, 09:00, 10:00.
        #expect(abs((profile.startSpread ?? 0) - (2.0 / 3.0 * 3_600).squareRoot()) < 0.001)
        #expect(profile.longestFocusRun?.start == date(cal, 19, 9))
        #expect(profile.longestFocusRun?.duration == 1_800)
        #expect(profile.shortDrifts == 2)
        #expect(profile.focusSeconds == 16 * 180)
        #expect(profile.driftSeconds == 180 + 360 + 300)
        #expect(profile.balance == 2_880.0 / (2_880 + 840))
        #expect(ReportText.profile(profile)
                == "Focus typically starts at 09:00 (3 days with a focus start); start times vary by about 49 min; longest focus run 30 min; 2 short drifts under 6 min; focus is 77% of focus and drift time.")
    }

    @Test func anEvenNumberOfFocusDaysUsesTheMiddleTwoAndAnEmptyWeekHasNoProfile() {
        let blocks = run(date(cal, 19, 9), 1, .focus) + run(date(cal, 20, 10), 1, .focus)
        #expect(WeekReport(containing: date(cal, 19, 12), blocks: blocks, calendar: cal).profile.typicalFocusStart == 570)
        let empty = WeekReport(containing: date(cal, 19, 12), blocks: run(date(cal, 19, 9), 3, nil), calendar: cal).profile
        #expect(empty.typicalFocusStart == nil)
        #expect(empty.startSpread == nil)
        #expect(empty.longestFocusRun == nil)
        #expect(empty.balance == nil)
        #expect(ReportText.profile(empty) == "No focus this week; 0 short drifts under 6 min.")
    }
}

@Suite struct CorrectionPrecedenceTests {
    @Test func aCorrectionOutranksTheModelInEveryMetric() throws {
        let cal = calendar()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        let start = date(cal, 20, 9)
        try store.save(Segment(start: start, end: start.addingTimeInterval(540), excluded: false, bundleID: "com.example.chat",
                               appName: "Chat", windowTitle: nil, url: nil))
        let stored = try store.blocks(from: start, to: start.addingTimeInterval(540))
        try store.applyClassifications(stored.map { BlockClassification(blockStart: $0.start, revision: $0.revision, label: .drift, reason: "Chat", confidence: 0.8) },
                                       rejected: [], provider: "openrouter", model: "m", at: start.addingTimeInterval(900))
        try store.correct(blockStart: start.addingTimeInterval(180), to: .focus, note: "Planning", at: start.addingTimeInterval(960))
        // A model answer for the corrected block that was in flight does not replace the correction.
        try store.applyClassifications([BlockClassification(blockStart: start.addingTimeInterval(180), revision: stored[1].revision, label: .drift, reason: "Chat", confidence: 1)],
                                       rejected: [], provider: "openrouter", model: "m", at: start.addingTimeInterval(990))
        let blocks = try store.blocks(from: start, to: start.addingTimeInterval(540))
        let week = WeekReport(containing: start, blocks: blocks, calendar: cal)
        let day = week.days[1]
        #expect(day.totals.focus == 180)
        #expect(day.totals.drift == 360)
        #expect(day.totals.focusShare == 1.0 / 3)
        #expect(day.spans.map(\.category) == [.drift, .focus, .drift])
        #expect(week.rhythm[18].seconds.focus == 180 && week.rhythm[18].seconds.drift == 360)
        #expect(week.profile.focusDays == 1)
        #expect(week.profile.typicalFocusStart == 9 * 60 + 3)
        #expect(week.profile.balance == 1.0 / 3)
        #expect(week.profile.longestFocusRun?.start == start.addingTimeInterval(180))
        #expect(week.profile.shortDrifts == 2)
        #expect(week.heatmap[1 * 24 + 9].seconds.focus == 180)
    }
}

@Suite struct ReportSelectionTests {
    private let cal = calendar()

    @Test func openingSelectsTodayAndTheCurrentHourWhateverWasSelectedBefore() {
        // The model was built on Monday and the user browsed to the Sunday before; the window opens on Wednesday.
        var launched = ReportSelection(now: date(cal, 19, 8, 10), calendar: cal)
        launched.moveDay(by: -1, now: date(cal, 19, 8, 11))
        #expect(cal.isDate(launched.day, inSameDayAs: date(cal, 18, 12)))
        let opened = ReportSelection(now: date(cal, 21, 15, 20), calendar: cal)
        #expect(opened.isToday(at: date(cal, 21, 15, 20)))
        #expect(opened.hour == date(cal, 21, 15))
    }

    @Test func todayFollowsMidnightAndABrowsedDayStays() {
        var selection = ReportSelection(now: date(cal, 20, 23, 30), calendar: cal)
        selection.followClock(now: date(cal, 21, 0, 1))
        selection.settle(now: date(cal, 21, 0, 1), firstBlock: nil)
        #expect(selection.interval.start == date(cal, 21, 0))
        #expect(selection.hour == date(cal, 21, 0))
        // A day the user chose stays when the clock passes midnight.
        selection.choose(day: date(cal, 19, 12), now: date(cal, 21, 23, 50))
        selection.settle(now: date(cal, 21, 23, 50), firstBlock: date(cal, 19, 9, 3))
        #expect(selection.hour == date(cal, 19, 9))
        selection.followClock(now: date(cal, 22, 0, 5))
        #expect(selection.interval.start == date(cal, 19, 0))
        // Choosing a later day than today selects today.
        selection.choose(day: date(cal, 25, 12), now: date(cal, 22, 0, 6))
        #expect(selection.isToday(at: date(cal, 22, 0, 6)))
    }

    @Test func theMidnightHourThenThePreviousDaySnapsToThatDaysHours() {
        var selection = ReportSelection(now: date(cal, 21, 0, 10), calendar: cal)
        #expect(selection.hour == date(cal, 21, 0))
        // Wednesday's 00:00 is Tuesday's end, which is not one of Tuesday's hours.
        selection.moveDay(by: -1, now: date(cal, 21, 0, 11))
        selection.settle(now: date(cal, 21, 0, 11), firstBlock: date(cal, 20, 13, 30))
        #expect(selection.hour == date(cal, 20, 13))
        selection.moveHour(by: 1)
        #expect(selection.hour == date(cal, 20, 14))
        selection.moveDay(by: -1, now: date(cal, 21, 0, 12))
        selection.settle(now: date(cal, 21, 0, 12), firstBlock: nil)
        #expect(selection.hour == date(cal, 19, 0))
        // No day after today.
        var today = ReportSelection(now: date(cal, 21, 10), calendar: cal)
        today.moveDay(by: 1, now: date(cal, 21, 10))
        #expect(today.isToday(at: date(cal, 21, 10)))
    }

    @Test func aClockChangeDayHasItsOwnHours() {
        var selection = ReportSelection(now: date(cal, 2, 9, month: 11), calendar: cal)
        selection.moveDay(by: -1, now: date(cal, 2, 9, month: 11))
        selection.settle(now: date(cal, 2, 9, month: 11), firstBlock: nil)
        #expect(selection.hours.count == 25)
        #expect(selection.hour == date(cal, 1, 0, month: 11))
        selection.moveHour(by: 24)
        #expect(selection.hour == date(cal, 1, 23, month: 11))
        selection.moveHour(by: 1)
        #expect(selection.hour == date(cal, 1, 23, month: 11))
        // The hourly zoom follows a selected block into the repeated hour, by elapsed time.
        selection.showHour(containing: date(cal, 1, 0, month: 11).addingTimeInterval(2.5 * 3_600))
        #expect(selection.hour == date(cal, 1, 0, month: 11).addingTimeInterval(2 * 3_600))
        var spring = ReportSelection(now: date(cal, 8, 20, month: 3), calendar: cal)
        #expect(spring.hours.count == 23)
        #expect(spring.hour == date(cal, 8, 20, month: 3))
        spring.showHour(containing: date(cal, 9, 0, month: 3))
        #expect(spring.hour == date(cal, 8, 20, month: 3))
        // Whole-hour changes leave every hour an hour long, the last ending at midnight.
        for day in [selection, spring] {
            #expect(day.hours.allSatisfy { ReportPeriod.hour(startingAt: $0, in: day.interval).duration == 3_600 })
            #expect(ReportPeriod.hour(startingAt: day.hours.last!, in: day.interval).end == day.interval.end)
        }
    }

    @Test func theLastHourOfAHalfHourClockChangeDayStopsAtMidnight() {
        let howe = calendar("Australia/Lord_Howe")
        // The clocks go back half an hour on 5 April 2026 (24.5 hours) and forward on 4 October (23.5 hours).
        for (day, month, count) in [(5, 4, 25), (4, 10, 24)] {
            var selection = ReportSelection(now: date(howe, day, 12, month: month), calendar: howe)
            #expect(selection.hours.count == count)
            selection.showHour(containing: selection.interval.end.addingTimeInterval(-1))
            let last = ReportPeriod.hour(startingAt: selection.hour, in: selection.interval)
            #expect(last.start == date(howe, day, 23, 30, month: month))
            #expect(last.end == selection.interval.end)
            #expect(last.duration == 1_800)
            #expect(selection.hours.dropLast().allSatisfy { ReportPeriod.hour(startingAt: $0, in: selection.interval).duration == 3_600 })
            // The header names the same span, ending at midnight.
            func time(_ date: Date, asEnd: Bool = false) -> String {
                ReportText.time(date, calendar: howe, locale: Locale(identifier: "en_GB"), asEnd: asEnd)
            }
            #expect(time(last.end, asEnd: true) == time(selection.interval.start))
            // The hour holds the day's last block and not the next day's first.
            let midnight = selection.interval.end
            let blocks = [block(midnight.addingTimeInterval(-Block.length), .focus), block(midnight, .drift)]
            #expect(blocks.filter { last.start <= $0.start && $0.start < last.end }.map(\.start) == [blocks[0].start])
            #expect(DayReport(day: last.start, blocks: blocks, calendar: howe).blocks.map(\.start) == [blocks[0].start])
        }
    }
}

@Suite struct ReportTextTests {
    @Test func durationsRoundToTheMinute() {
        #expect(ReportText.duration(0) == "0 min")
        #expect(ReportText.duration(29) == "0 min")
        #expect(ReportText.duration(2_700) == "45 min")
        #expect(ReportText.duration(7_200) == "2 h")
        #expect(ReportText.duration(7_530) == "2 h 6 min")
        #expect(ReportText.clock(570) == "09:30")
    }
}
