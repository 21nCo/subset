import Foundation

// Report math for the timeline and weekly reports: pure functions of stored blocks and a calendar, so every number the
// window shows comes from the store and can be tested without the app.
//
// How each kind of time counts, in every metric below:
// - A block's label is the user's correction when there is one, otherwise the model's; pending and failed blocks are
//   unclassified. The store keeps only the latest correction, and a model answer never replaces it.
// - A correction covers the whole block, its anonymous excluded time included: the user knows what that time was. A
//   model label covers only the recorded, non-excluded time it judged; the rest of the block stays excluded.
// - Idle, paused, asleep, and other unrecorded time is in no total. It is the part of a block or a day that holds
//   nothing, and it ends a contiguous span or run.
// - Focus percentages divide by classified time (focus, neutral, and drift) only, never by unclassified or excluded time.

/// The categories a block's time falls into in reports.
public enum TimeCategory: String, CaseIterable, Sendable {
    case focus, neutral, drift, unclassified, excluded

    public init(_ label: BlockLabel) {
        switch label {
        case .focus: self = .focus
        case .neutral: self = .neutral
        case .drift: self = .drift
        }
    }

    public var title: String { rawValue.capitalized }
}

/// Seconds per category.
public struct CategorySeconds: Equatable, Sendable {
    public var focus = 0.0, neutral = 0.0, drift = 0.0, unclassified = 0.0, excluded = 0.0

    public init() {}

    public subscript(category: TimeCategory) -> Double {
        get {
            switch category {
            case .focus: focus
            case .neutral: neutral
            case .drift: drift
            case .unclassified: unclassified
            case .excluded: excluded
            }
        }
        set {
            switch category {
            case .focus: focus = newValue
            case .neutral: neutral = newValue
            case .drift: drift = newValue
            case .unclassified: unclassified = newValue
            case .excluded: excluded = newValue
            }
        }
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        var sum = lhs
        for category in TimeCategory.allCases { sum[category] += rhs[category] }
        return sum
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }

    public var classified: Double { focus + neutral + drift }
    public var recorded: Double { classified + unclassified + excluded }

    /// Focus over classified time; nil when nothing is classified.
    public var focusShare: Double? { classified > 0 ? focus / classified : nil }
    /// Focus over focus plus drift; nil when there is neither.
    public var focusDriftBalance: Double? { focus + drift > 0 ? focus / (focus + drift) : nil }
}

extension Block {
    /// The label reports use: the correction or the model's label; nil while pending or failed.
    public var reportLabel: BlockLabel? {
        labeling.state == .classified || labeling.state == .corrected ? labeling.label : nil
    }

    /// The block's recorded time per category. Unrecorded time in the block is in none of them.
    public var categorySeconds: CategorySeconds {
        var seconds = CategorySeconds()
        switch (reportLabel, labeling.state) {
        case (let label?, .corrected):
            seconds[TimeCategory(label)] = activeSeconds + excludedSeconds
        case (let label?, _):
            seconds[TimeCategory(label)] = activeSeconds
            seconds.excluded = excludedSeconds
        case (nil, _):
            seconds.unclassified = activeSeconds
            seconds.excluded = excludedSeconds
        }
        return seconds
    }

    /// The one category the timeline draws the block in: its label, else unclassified when it holds recorded app time,
    /// else excluded.
    public var category: TimeCategory {
        if let label = reportLabel { return TimeCategory(label) }
        return activeSeconds > 0 ? .unclassified : .excluded
    }
}

/// Consecutive blocks of one category with no unrecorded bucket between them.
public struct LabeledSpan: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var category: TimeCategory
    public var blockCount: Int
    /// Recorded seconds of the span's blocks in its category.
    public var seconds: Double

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Merges `blocks` (in start order) into spans. A block that starts where the previous one ended continues its span
    /// when both have the same category; a missing bucket (idle, paused, or asleep for a whole block) ends it.
    public static func spans(of blocks: [Block]) -> [LabeledSpan] {
        var result: [LabeledSpan] = []
        for block in blocks {
            let category = block.category
            if var last = result.last, last.category == category, last.end == block.start {
                last.end = block.end
                last.blockCount += 1
                last.seconds += block.categorySeconds[category]
                result[result.count - 1] = last
            } else {
                result.append(LabeledSpan(start: block.start, end: block.end, category: category, blockCount: 1,
                                          seconds: block.categorySeconds[category]))
            }
        }
        return result
    }
}

/// Time in one app or on one site.
public struct UsageTotal: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var seconds: Double
}

/// A half-hour of local wall-clock time and the time recorded in it.
public struct RhythmSlot: Equatable, Sendable {
    /// Minutes after local midnight, by the clock: 0, 30, …, 1410.
    public var minuteOfDay: Int
    public var seconds = CategorySeconds()
}

/// One hour of one day of the week.
public struct HeatmapCell: Equatable, Sendable {
    /// The day's index in the week, 0 for its first day.
    public var dayIndex: Int
    /// The local clock hour, 0–23.
    public var hour: Int
    public var seconds = CategorySeconds()
}

/// The day and week intervals reports cover, from the calendar, so a day is 23 or 25 hours long when the clocks change.
public enum ReportPeriod {
    public static func day(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
    }

    public static func week(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    }

    /// The seven day intervals of the week holding `date`.
    public static func days(ofWeekContaining date: Date, calendar: Calendar) -> [DateInterval] {
        let week = week(containing: date, calendar: calendar)
        return (0..<7).map { offset in
            day(containing: calendar.date(byAdding: .day, value: offset, to: week.start) ?? week.start, calendar: calendar)
        }
    }

    /// The starts of a day's hours by elapsed time, so a day the clocks change has 23 or 25 of them. The day's end is
    /// not one of them.
    public static func hours(of day: DateInterval) -> [Date] {
        Array(stride(from: day.start, to: day.end, by: 3_600))
    }

    /// Minutes after local midnight as the clock shows them, so 09:00 is 540 on a day the clocks changed too.
    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Where a span of `day` sits on a clock-time axis, in minutes after midnight: from its start's clock time to its
    /// end's, the day's end being 1440. When the clocks go back inside the span or at its end, it reaches at least the
    /// latest clock time it passed, so it never ends before it starts: the instant they go back closes the first pass
    /// through the hour. Spans are placed one at a time, so a span in the second pass overlaps one in the first. A span
    /// across the hour the clocks skip forward is drawn across it, from its start's clock time to its end's.
    public static func clockMinutes(of span: LabeledSpan, day: DateInterval, calendar: Calendar) -> ClosedRange<Double> {
        func minutes(_ date: Date) -> Double {
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        }
        let start = minutes(span.start)
        var end = span.end >= day.end ? 1_440 : minutes(span.end)
        var date = span.start
        while let change = calendar.timeZone.nextDaylightSavingTimeTransition(after: date), change <= span.end {
            // The clock just before the change: its reading at the change plus the hour (or so) it went back.
            let back = calendar.timeZone.secondsFromGMT(for: change.addingTimeInterval(-1)) - calendar.timeZone.secondsFromGMT(for: change)
            if back > 0 { end = max(end, minutes(change) + Double(back) / 60) }
            date = change
        }
        return start...max(start, end)
    }

    static func rhythm(of blocks: [Block], calendar: Calendar) -> [RhythmSlot] {
        var slots = (0..<48).map { RhythmSlot(minuteOfDay: $0 * 30) }
        // When the clocks go back, the repeated half-hours fall into the same slot; when they go forward, the skipped
        // ones stay empty.
        for block in blocks {
            let slot = minuteOfDay(block.start, calendar: calendar) / 30
            slots[slot].seconds += block.categorySeconds
        }
        return slots
    }
}

/// The day and hour the reports window shows. Opening it selects today and the current hour; a selection on today
/// follows the clock past midnight; a day the user chose stays while the window is open; and the hourly zoom always
/// shows one of the selected day's hours.
public struct ReportSelection: Equatable, Sendable {
    public let calendar: Calendar
    /// An instant in the selected day, never after the last time the selection was brought up to date.
    public private(set) var day: Date
    /// The start of the hour the hourly zoom shows, one of `hours`.
    public private(set) var hour: Date
    /// When the selection was last brought up to date, to tell whether it was on that day's today.
    private var checkedAt: Date

    /// Today and the current hour, as the window opens.
    public init(now: Date, calendar: Calendar) {
        self.calendar = calendar
        day = now
        checkedAt = now
        hour = now
        snapHour(now: now, firstBlock: nil, current: true)
    }

    public var interval: DateInterval { ReportPeriod.day(containing: day, calendar: calendar) }
    public var hours: [Date] { ReportPeriod.hours(of: interval) }

    public func isToday(at now: Date) -> Bool { calendar.isDate(day, inSameDayAs: now) }

    /// Selects the day holding `date`, or today for a later one. Its hour is set by the next `settle`.
    public mutating func choose(day date: Date, now: Date) {
        day = min(date, now)
        checkedAt = now
    }

    /// The day `days` before or after the selected one, up to today.
    public mutating func moveDay(by days: Int, now: Date) {
        guard let next = calendar.date(byAdding: .day, value: days, to: day), calendar.startOfDay(for: next) <= now else { return }
        choose(day: next, now: now)
    }

    /// Brings the day up to date before a read: a selection on today moves to the new today after midnight.
    public mutating func followClock(now: Date) {
        if calendar.isDate(day, inSameDayAs: checkedAt) || day > now { day = now }
        checkedAt = now
    }

    /// After a read of the selected day: keeps the hour when it is one of the day's hours, otherwise moves it to the
    /// current hour on today and to the hour of the day's first block, or its first hour, on another day.
    public mutating func settle(now: Date, firstBlock: Date?) {
        snapHour(now: now, firstBlock: firstBlock, current: false)
    }

    public mutating func moveHour(by offset: Int) {
        let hours = hours
        guard let index = hours.firstIndex(of: hour), hours.indices.contains(index + offset) else { return }
        hour = hours[index + offset]
    }

    /// The hour of the selected day that holds `date`, so the hourly zoom follows a selected block.
    public mutating func showHour(containing date: Date) {
        let interval = interval
        guard interval.start <= date, date < interval.end, let containing = hours.last(where: { $0 <= date }) else { return }
        hour = containing
    }

    private mutating func snapHour(now: Date, firstBlock: Date?, current: Bool) {
        let interval = interval, hours = hours
        if !current, hours.contains(hour) { return }
        let anchor = interval.start <= now && now < interval.end ? now : firstBlock ?? interval.start
        hour = hours.last { $0 <= anchor } ?? interval.start
    }
}

/// One day's report: the timeline, totals, top apps and sites, and the half-hour rhythm.
public struct DayReport: Sendable {
    public let interval: DateInterval
    /// The day's blocks in start order. A block belongs to the day its start falls in; blocks start on local
    /// three-minute marks, so none crosses midnight.
    public let blocks: [Block]
    public let totals: CategorySeconds
    /// Recorded, non-excluded time per app, longest first. Excluded apps are never named.
    public let apps: [UsageTotal]
    /// Per site: the time of each block's main app in that block, for the site of its longest segment. The store keeps
    /// one site per block, so this approximates site time to three-minute resolution.
    public let hosts: [UsageTotal]
    /// 48 half-hour slots of local clock time.
    public let rhythm: [RhythmSlot]
    /// Contiguous spans of one category, split at midnight because the day's blocks end there.
    public let spans: [LabeledSpan]
    /// Blocks waiting for a label and blocks the provider could not label.
    public let pendingCount: Int
    public let failedCount: Int

    public init(day date: Date, blocks: [Block], calendar: Calendar) {
        let interval = ReportPeriod.day(containing: date, calendar: calendar)
        self.interval = interval
        let blocks = blocks.filter { interval.start <= $0.start && $0.start < interval.end }.sorted { $0.start < $1.start }
        self.blocks = blocks
        totals = blocks.reduce(CategorySeconds()) { $0 + $1.categorySeconds }
        var apps: [String: UsageTotal] = [:], hosts: [String: UsageTotal] = [:]
        for block in blocks {
            for app in block.apps {
                apps[app.bundleID, default: UsageTotal(id: app.bundleID, name: app.appName, seconds: 0)].seconds += app.seconds
            }
            if let host = block.dominantURL?.host, let main = block.apps.first(where: { $0.bundleID == block.dominantBundleID }) {
                hosts[host, default: UsageTotal(id: host, name: host, seconds: 0)].seconds += main.seconds
            }
        }
        let longestFirst: (UsageTotal, UsageTotal) -> Bool = { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
        self.apps = apps.values.sorted(by: longestFirst)
        self.hosts = hosts.values.sorted(by: longestFirst)
        rhythm = ReportPeriod.rhythm(of: blocks, calendar: calendar)
        spans = LabeledSpan.spans(of: blocks)
        pendingCount = blocks.filter { $0.labeling.state == .pending && $0.activeSeconds > 0 }.count
        failedCount = blocks.filter { $0.labeling.state == .failed }.count
    }

    /// The end of the day's latest block.
    public var latestBlockEnd: Date? { blocks.last?.end }
}

/// The week's focus habits.
public struct FocusProfile: Equatable, Sendable {
    /// The median of each day's focus start, in minutes after local midnight; nil when no day had one. A day's focus
    /// start is the start of the first focus run that begins on it: a run continuing from the evening before is that
    /// evening's.
    public var typicalFocusStart: Int?
    /// The days on which a focus run begins.
    public var focusDays: Int
    /// How far the days' first focus starts spread: their standard deviation in minutes, nil with fewer than two days.
    public var startSpread: Double?
    /// The longest run of consecutive focus blocks in the week, by elapsed time. Runs continue across midnight.
    public var longestFocusRun: LabeledSpan?
    /// Drift runs starting in the week with less than six minutes of drift time; one continuing from before the week is
    /// never short, and one still running at the week's end is judged by its time up to that end.
    public var shortDrifts: Int
    /// Focus and drift time; their balance is focus over both.
    public var focusSeconds: Double
    public var driftSeconds: Double

    public static let shortDriftLimit: TimeInterval = 6 * 60

    public var balance: Double? { focusSeconds + driftSeconds > 0 ? focusSeconds / (focusSeconds + driftSeconds) : nil }

    /// `before` holds blocks before the week, so a run continuing into its first day is not counted as a start there.
    init(days: [DayReport], before: [Block], calendar: Calendar) {
        let weekStart = days.first?.interval.start ?? .distantPast
        let throughWeek = LabeledSpan.spans(of: before.sorted { $0.start < $1.start } + days.flatMap(\.blocks))
        let runs = throughWeek.filter { $0.category == .focus }
        let starts = days.compactMap { day in
            runs.first { day.interval.start <= $0.start && $0.start < day.interval.end }.map { ReportPeriod.minuteOfDay($0.start, calendar: calendar) }
        }.sorted()
        focusDays = starts.count
        if starts.isEmpty {
            typicalFocusStart = nil
        } else {
            let middle = starts.count / 2
            typicalFocusStart = starts.count.isMultiple(of: 2) ? (starts[middle - 1] + starts[middle]) / 2 : starts[middle]
        }
        if starts.count >= 2 {
            let mean = Double(starts.reduce(0, +)) / Double(starts.count)
            startSpread = (starts.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(starts.count)).squareRoot()
        } else {
            startSpread = nil
        }
        let spans = LabeledSpan.spans(of: days.flatMap(\.blocks))
        longestFocusRun = spans.filter { $0.category == .focus }.max { $0.duration != $1.duration ? $0.duration < $1.duration : $0.start > $1.start }
        // A drift continuing from before the week is not short however little of it falls in the week.
        shortDrifts = throughWeek.filter { $0.category == .drift && $0.start >= weekStart && $0.seconds < Self.shortDriftLimit }.count
        let totals = days.reduce(CategorySeconds()) { $0 + $1.totals }
        focusSeconds = totals.focus
        driftSeconds = totals.drift
    }
}

/// One week's report: per-day bars, the half-hour rhythm, the hour-by-weekday focus heatmap, and the focus profile.
public struct WeekReport: Sendable {
    public let interval: DateInterval
    /// The week's seven days, first day first; each carries its bar totals and calendar spans.
    public let days: [DayReport]
    public let totals: CategorySeconds
    /// The week's time per half-hour of local clock time, summed over its days.
    public let rhythm: [RhythmSlot]
    /// 7 × 24 cells, day by day and hour by hour; a cell's focus share is focus over its classified time.
    public let heatmap: [HeatmapCell]
    public let profile: FocusProfile

    /// `blocks` may include the block that ends as the week starts, so a focus run continuing into its first day is
    /// told from one that starts there.
    public init(containing date: Date, blocks: [Block], calendar: Calendar) {
        let interval = ReportPeriod.week(containing: date, calendar: calendar)
        self.interval = interval
        let days = ReportPeriod.days(ofWeekContaining: date, calendar: calendar).map { DayReport(day: $0.start, blocks: blocks, calendar: calendar) }
        self.days = days
        totals = days.reduce(CategorySeconds()) { $0 + $1.totals }
        var rhythm = (0..<48).map { RhythmSlot(minuteOfDay: $0 * 30) }
        var heatmap = (0..<7).flatMap { day in (0..<24).map { HeatmapCell(dayIndex: day, hour: $0) } }
        for (index, day) in days.enumerated() {
            for (slot, value) in day.rhythm.enumerated() { rhythm[slot].seconds += value.seconds }
            for block in day.blocks {
                let cell = index * 24 + ReportPeriod.minuteOfDay(block.start, calendar: calendar) / 60
                heatmap[cell].seconds += block.categorySeconds
            }
        }
        self.rhythm = rhythm
        self.heatmap = heatmap
        profile = FocusProfile(days: days, before: blocks.filter { $0.start < interval.start }, calendar: calendar)
    }

    public var latestBlockEnd: Date? { days.compactMap(\.latestBlockEnd).max() }
}

/// Plain-text summaries, so every chart can be read without seeing it (VoiceOver reads them too).
public enum ReportText {
    /// Rounded to the minute: "0 min", "45 min", "2 h", "2 h 5 min".
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        switch (minutes / 60, minutes % 60) {
        case (0, let rest): return "\(rest) min"
        case (let hours, 0): return "\(hours) h"
        case (let hours, let rest): return "\(hours) h \(rest) min"
        }
    }

    public static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    /// "09:30" for 570.
    public static func clock(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    /// A clock time in minutes after midnight in `locale`'s style, "2:30 PM" or "14:30". It names the wall time alone,
    /// so it reads the same on a day that skipped or repeated that time.
    public static func clock(_ minuteOfDay: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minuteOfDay / 60 % 24, minute: minuteOfDay % 60)) ?? .distantPast
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// A time of day in `calendar`'s zone and `locale`'s style, "2:30 PM" or "14:30". A wall time the clocks show twice,
    /// in the hour repeated when they go back, names its zone ("1:30 AM EDT", "1:30 AM EST") so the two passes read
    /// differently. As the end of a span (`asEnd`), the instant the clocks go back closes the first pass and reads as
    /// that pass's clock ("2:00 AM EDT"), not as the start of the second.
    public static func time(_ date: Date, calendar: Calendar, locale: Locale, asEnd: Bool = false) -> String {
        let zone = calendar.timeZone
        var shown: (offset: Int, abbreviation: String)?
        var next = zone.nextDaylightSavingTimeTransition(after: date.addingTimeInterval(-2 * 86_400))
        while let change = next, change <= date.addingTimeInterval(2 * 86_400) {
            let before = change.addingTimeInterval(-1)
            let back = zone.secondsFromGMT(for: before) - zone.secondsFromGMT(for: change)
            next = zone.nextDaylightSavingTimeTransition(after: change)
            // Going forward repeats nothing.
            guard back > 0 else { continue }
            if asEnd, date == change {
                shown = (zone.secondsFromGMT(for: before), zone.abbreviation(for: before) ?? "")
            } else if (change.addingTimeInterval(-Double(back))..<change.addingTimeInterval(Double(back))).contains(date) {
                shown = (zone.secondsFromGMT(for: date), zone.abbreviation(for: date) ?? "")
            }
        }
        let display = shown.flatMap { TimeZone(secondsFromGMT: $0.offset) } ?? zone
        let text = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: display))
        guard let shown, !shown.abbreviation.isEmpty else { return text }
        return text + " " + shown.abbreviation
    }

    /// Every category with time, then focus as a share of classified time.
    public static func totals(_ seconds: CategorySeconds) -> String {
        guard seconds.recorded > 0 else { return "No activity recorded." }
        let parts = TimeCategory.allCases.filter { seconds[$0] > 0 }.map { "\($0.title) \(duration(seconds[$0]))" }
        let share = seconds.focusShare.map { "Focus is \(percent($0)) of classified time." } ?? "Nothing is classified yet."
        return parts.joined(separator: ", ") + ". " + share
    }

    /// The half-hours with the most focus and the most drift.
    public static func rhythm(_ slots: [RhythmSlot], clock: (Int) -> String = clock) -> String {
        func peak(_ category: TimeCategory) -> String? {
            // The earliest slot wins a tie.
            guard let slot = slots.filter({ $0.seconds[category] > 0 }).max(by: {
                $0.seconds[category] != $1.seconds[category] ? $0.seconds[category] < $1.seconds[category] : $0.minuteOfDay > $1.minuteOfDay
            }) else { return nil }
            return "most \(category.rawValue) from \(clock(slot.minuteOfDay)) to \(clock((slot.minuteOfDay + 30) % 1440)) (\(duration(slot.seconds[category])))"
        }
        let parts = [peak(.focus), peak(.drift)].compactMap { $0 }
        return parts.isEmpty ? "No focus or drift recorded." : "Half-hour rhythm: " + parts.joined(separator: "; ") + "."
    }

    /// Focus and drift per day, naming each day with `dayName`.
    public static func bars(_ days: [DayReport], dayName: (DayReport) -> String) -> String {
        let parts = days.filter { $0.totals.recorded > 0 }.map { day in
            "\(dayName(day)): focus \(duration(day.totals.focus)), neutral \(duration(day.totals.neutral)), drift \(duration(day.totals.drift))"
                + (day.totals.unclassified > 0 ? ", unclassified \(duration(day.totals.unclassified))" : "")
        }
        return parts.isEmpty ? "No activity recorded this week." : parts.joined(separator: ". ") + "."
    }

    /// The hour of the week with the most focus.
    public static func heatmap(_ cells: [HeatmapCell], dayName: (Int) -> String, clock: (Int) -> String = clock) -> String {
        guard let best = cells.filter({ $0.seconds.focus > 0 }).max(by: { $0.seconds.focus != $1.seconds.focus ? $0.seconds.focus < $1.seconds.focus : ($0.dayIndex, $0.hour) > ($1.dayIndex, $1.hour) }) else {
            return "No focus recorded this week."
        }
        let hours = cells.filter { $0.seconds.focus > 0 }.count
        return "Focus in \(hours) hour\(hours == 1 ? "" : "s") of the week; the most on \(dayName(best.dayIndex)) from \(clock(best.hour * 60)) (\(duration(best.seconds.focus)))."
    }

    public static func profile(_ profile: FocusProfile, clock: (Int) -> String = clock) -> String {
        var parts: [String] = []
        if let start = profile.typicalFocusStart {
            parts.append("Focus typically starts at \(clock(start)) (\(profile.focusDays) day\(profile.focusDays == 1 ? "" : "s") with a focus start)")
        } else if profile.focusSeconds > 0 {
            parts.append("Focus continued from before the week, with no new focus start this week")
        } else {
            parts.append("No focus this week")
        }
        if let spread = profile.startSpread { parts.append("start times vary by about \(Int(spread.rounded())) min") }
        if let run = profile.longestFocusRun { parts.append("longest focus run \(duration(run.duration))") }
        parts.append("\(profile.shortDrifts) short drift\(profile.shortDrifts == 1 ? "" : "s") under 6 min")
        if let balance = profile.balance { parts.append("focus is \(percent(balance)) of focus and drift time") }
        return parts.joined(separator: "; ") + "."
    }
}
