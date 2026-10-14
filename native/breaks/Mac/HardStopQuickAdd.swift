import Foundation

// The rules behind the hard-stop editor in Settings and the menu bar's **Hard stop at…** panel: the editor's values,
// the quick-add times, saving only valid stops, and the text that describes a stop. Pure Foundation, so the hostless
// Mac test bundle compiles and tests it.

/// The values of the **Hard stop at…** panel and the one-off stop it creates.
struct HardStopQuickAdd: Equatable {
    static let defaultName = "Hard stop"
    static let lengthRange = 5...(16 * 60)

    var hour: Int
    var minute: Int
    var lengthMinutes = 30
    var name = defaultName

    /// Opens with a start 30 minutes from `now`, rounded up to the next 5 minutes.
    init(now: Date, calendar: Calendar) {
        // Worked out in elapsed time, so a daylight-saving change in the next 30 minutes gives a clock time that exists.
        let later = now.addingTimeInterval(30 * 60)
        let parts = calendar.dateComponents([.minute, .second, .nanosecond], from: later)
        let past = TimeInterval((parts.minute ?? 0) % 5 * 60 + (parts.second ?? 0)) + TimeInterval(parts.nanosecond ?? 0) / 1e9
        let first = past > 0 ? later.addingTimeInterval(5 * 60 - past) : later
        let clock = calendar.dateComponents([.hour, .minute], from: first)
        hour = clock.hour ?? 0
        minute = clock.minute ?? 0
        // When clocks go back, a time in the repeated hour means its first pass, which may already be over, and the
        // stop would wait a day. Step on 5 minutes at a time, past midnight if need be, to the first time whose stop
        // starts at that very moment. A day of steps covers any change; if none matches, the first time stays.
        for step in 0...24 * 12 {
            let candidate = first.addingTimeInterval(TimeInterval(step * 5 * 60))
            let clock = calendar.dateComponents([.hour, .minute], from: candidate)
            var values = self
            (values.hour, values.minute) = (clock.hour ?? 0, clock.minute ?? 0)
            if let start = values.start(now: now, calendar: calendar), abs(start.timeIntervalSince(candidate)) < 1 {
                self = values
                break
            }
        }
    }

    /// When the stop that `stop(now:calendar:)` creates starts.
    func start(now: Date, calendar: Calendar) -> Date? {
        let stop = stop(now: now, calendar: calendar)
        guard case .once(let day) = stop.repeats,
              let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
        return stop.start(onDayOf: date, calendar: calendar)
    }

    /// True when the chosen time is earlier than `now` today, so the stop is for tomorrow. A time in the current
    /// minute is today and starts at once.
    func startsTomorrow(now: Date, calendar: Calendar) -> Bool {
        guard let today = stop(onDayOf: now, calendar: calendar).start(onDayOf: now, calendar: calendar),
              let minuteStart = calendar.dateInterval(of: .minute, for: now)?.start else { return true }
        return today < minuteStart
    }

    /// The one-off stop for today or tomorrow, with the default warnings, escape hatch, and call behavior.
    func stop(now: Date, calendar: Calendar) -> HardStop {
        guard startsTomorrow(now: now, calendar: calendar),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return stop(onDayOf: now, calendar: calendar)
        }
        return stop(onDayOf: tomorrow, calendar: calendar)
    }

    private func stop(onDayOf day: Date, calendar: Calendar) -> HardStop {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return HardStop(
            name: trimmed.isEmpty ? Self.defaultName : trimmed,
            hour: hour,
            minute: minute,
            end: .after(TimeInterval(lengthMinutes * 60)),
            repeats: .once(on: day, calendar: calendar)
        )
    }
}

/// The hard-stop editor's values. Each kind of end, repeat, and escape hatch keeps its own values, so switching
/// back and forth in the editor does not lose them.
struct HardStopDraft: Equatable, Identifiable {
    enum EndKind: String, CaseIterable, Identifiable {
        case atTime
        case afterLength
        case untilDismissed

        var id: Self { self }
        var title: String {
            switch self {
            case .atTime: "At a time"
            case .afterLength: "After a length"
            case .untilDismissed: "Until dismissed"
            }
        }
    }

    enum RepeatKind: String, CaseIterable, Identifiable {
        case weekdays
        case once

        var id: Self { self }
        var title: String {
            switch self {
            case .weekdays: "On days"
            case .once: "Once"
            }
        }
    }

    enum EscapeKind: String, CaseIterable, Identifiable {
        case none
        case extend
        case dismissEarly

        var id: Self { self }
        var title: String {
            switch self {
            case .none: "None"
            case .extend: "Extend"
            case .dismissEarly: "Dismiss early"
            }
        }
    }

    let id: UUID
    /// True for a stop that is not in the settings yet.
    let isNew: Bool
    var isEnabled: Bool
    var name: String
    var hour: Int
    var minute: Int
    var endKind: EndKind
    var endHour: Int
    var endMinute: Int
    var lengthMinutes: Int
    var repeatKind: RepeatKind
    var weekdays: Set<Int>
    /// The day of a one-off stop. Choosing one replaces a stored day that does not exist.
    var date: Date {
        didSet { storedImpossibleDate = nil }
    }
    /// The stored day of a one-off stop that names no calendar day, such as 31 April. It is saved as it is, so the
    /// editor shows its error and refuses to save, until the user chooses a date.
    private(set) var storedImpossibleDate: DateComponents?
    var warningMinutes: [Int]
    var escapeKind: EscapeKind
    var extendMinutes: Int
    var extendTimes: Int
    var duringCalls: HardStop.CallBehavior
    /// The escape hatch of a stored stop that lasts until dismissed, kept while the editor hides the escape hatch.
    let storedUntilDismissedEscapeHatch: HardStop.EscapeHatch?

    /// A new stop with the model's defaults, at 5:00 PM on weekdays.
    static func new(now: Date) -> HardStopDraft {
        HardStopDraft(HardStop(name: HardStopQuickAdd.defaultName, hour: 17, minute: 0), isNew: true, now: now)
    }

    init(_ stop: HardStop, isNew: Bool = false, now: Date, calendar: Calendar = .autoupdatingCurrent) {
        id = stop.id
        self.isNew = isNew
        isEnabled = stop.isEnabled
        name = stop.name
        hour = stop.hour
        minute = stop.minute
        endKind = .afterLength
        endHour = (stop.hour + 1) % 24
        endMinute = stop.minute
        lengthMinutes = 30
        switch stop.end {
        case .at(let hour, let minute):
            endKind = .atTime
            endHour = hour
            endMinute = minute
        case .after(let duration):
            lengthMinutes = Int((duration / 60).rounded())
        case .untilDismissed:
            endKind = .untilDismissed
        }
        repeatKind = .weekdays
        weekdays = [2, 3, 4, 5, 6]
        date = now
        switch stop.repeats {
        case .weekdays(let days):
            weekdays = days
        case .once(let day):
            repeatKind = .once
            let parts = DateComponents(year: day.year, month: day.month, day: day.day)
            if let resolved = calendar.date(from: parts),
               calendar.dateComponents([.year, .month, .day], from: resolved) == parts {
                date = resolved
            } else {
                storedImpossibleDate = day
            }
        }
        warningMinutes = stop.warningMinutes
        // The model's default extension, shown when the user switches to Extend.
        escapeKind = .extend
        extendMinutes = 15
        extendTimes = 1
        switch stop.escapeHatch {
        case .none:
            escapeKind = .none
        case .extend(let minutes, let times):
            extendMinutes = minutes
            extendTimes = times
        case .dismissEarly:
            escapeKind = .dismissEarly
        }
        duringCalls = stop.duringCalls
        storedUntilDismissedEscapeHatch = !isNew && stop.end == .untilDismissed ? stop.escapeHatch : nil
    }

    /// The editor hides the escape hatch for a stop that lasts until dismissed; such a stop can always be dismissed.
    var showsEscapeHatch: Bool { endKind != .untilDismissed }

    func stop(calendar: Calendar) -> HardStop {
        let end: HardStop.End = switch endKind {
        case .atTime: .at(hour: endHour, minute: endMinute)
        case .afterLength: .after(TimeInterval(lengthMinutes * 60))
        case .untilDismissed: .untilDismissed
        }
        let shownEscapeHatch: HardStop.EscapeHatch = switch escapeKind {
        case .none: .none
        case .extend: .extend(minutes: extendMinutes, times: extendTimes)
        case .dismissEarly: .dismissEarly
        }
        // A stop that lasts until dismissed keeps its stored escape hatch; a new one, or one switched to it, saves
        // dismiss early.
        let escapeHatch = showsEscapeHatch ? shownEscapeHatch : storedUntilDismissedEscapeHatch ?? .dismissEarly
        return HardStop(
            id: id,
            name: name,
            isEnabled: isEnabled,
            hour: hour,
            minute: minute,
            end: end,
            repeats: repeatKind == .weekdays ? .weekdays(weekdays) : storedImpossibleDate.map { .once($0) } ?? .once(on: date, calendar: calendar),
            warningMinutes: warningMinutes,
            escapeHatch: escapeHatch,
            duringCalls: duringCalls
        )
    }
}

extension BreakSettings {
    /// Saves `stop`, replacing the stop with its id, or adding it at the end when `isNew`, only when the settings are
    /// then free of errors for it. Returns those errors (for the stop and for the whole list) and leaves the settings
    /// unchanged when there are any. An edit of a stop that is gone (deleted, or a one-off stop that ran) is not
    /// saved, so its occurrence does not run again.
    mutating func saveHardStop(_ stop: HardStop, isNew: Bool, now: Date, calendar: Calendar) -> [HardStopFieldError] {
        var next = self
        if let index = next.hardStops.firstIndex(where: { $0.id == stop.id }) {
            next.hardStops[index] = stop
        } else if isNew {
            next.hardStops.append(stop)
        } else {
            return [.init(stopID: stop.id, field: .list, message: "This hard stop was deleted or has already run.")]
        }
        let errors = next.hardStopErrors(now: now, calendar: calendar).filter { $0.stopID == nil || $0.stopID == stop.id }
        if errors.isEmpty { self = next }
        return errors
    }
}

extension BreakScheduler {
    /// The enabled stop whose next occurrence starts first after `now`, and that start. Repeating stops are looked up
    /// two weeks ahead, so a weekly one whose next day has no occurrence (the clocks skip its time) is still found.
    /// An occurrence that already ran, joined another, or was missed is skipped.
    func nextHardStop(after now: Date) -> (stop: HardStop, start: Date)? {
        let today = calendar.startOfDay(for: now)
        var next: (stop: HardStop, start: Date)?
        for stop in settings.hardStops where stop.isEnabled {
            let days: [Date] = switch stop.repeats {
            case .weekdays: (0...14).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
            case .once(let date): [calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))].compactMap { $0 }
            }
            let handled = snapshot.handledHardStops[stop.id.uuidString] ?? .min
            let start = days.lazy
                .compactMap { stop.occurrence(onDayOf: $0, calendar: calendar) }
                .first { $0.start > now && $0.key > handled }?.start
            if let start, start < next?.start ?? .distantFuture { next = (stop, start) }
        }
        return next
    }
}

/// The date a time picker edits for a stop's hour and minute. It is built on a day near today whose clocks do not
/// change, so every hour and minute exists once on it: on a day whose clocks change, a time they skip or repeat would
/// otherwise come back from the picker as another time.
enum HardStopClock {
    static func date(hour: Int, minute: Int, near now: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: referenceDay(near: now, calendar: calendar)) ?? now
    }

    static func time(of date: Date, calendar: Calendar) -> (hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The start of the first day from today on whose clocks do not change; today when none in the next two weeks.
    static func referenceDay(near now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        var day = today
        for _ in 0..<14 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let zone = calendar.timeZone
            if zone.secondsFromGMT(for: day) == zone.secondsFromGMT(for: next),
               zone.nextDaylightSavingTimeTransition(after: day).map({ $0 >= next }) ?? true {
                return day
            }
            day = next
        }
        return today
    }
}

/// The text Settings and the menu bar use for a hard stop.
enum HardStopText {
    /// A row summary such as "Weekdays 1:00 PM · 45 min".
    static func summary(of stop: HardStop, locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        func clock(_ hour: Int, _ minute: Int) -> String {
            calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)).map { $0.formatted(time) } ?? ""
        }
        let days: String = switch stop.repeats {
        case .weekdays(let weekdays): Self.days(weekdays, locale: locale, calendar: calendar)
        case .once(let date):
            calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))
                .map { $0.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated).day().month(.abbreviated)) } ?? ""
        }
        let end: String = switch stop.end {
        case .at(let hour, let minute): "until \(clock(hour, minute))"
        case .after(let duration): length(minutes: Int((duration / 60).rounded()))
        case .untilDismissed: "until dismissed"
        }
        return "\(days) \(clock(stop.hour, stop.minute)) · \(end)"
    }

    /// "45 min", "1 hr", or "1 hr 30 min".
    static func length(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        guard hours > 0 else { return "\(rest) min" }
        return rest > 0 ? "\(hours) hr \(rest) min" : "\(hours) hr"
    }

    /// "Next hard stop: Lunch at 1:00 PM", with "tomorrow" or the date when it is not today.
    static func next(_ stop: HardStop, start: Date, now: Date, locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) -> String {
        let format = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = start.formatted(format.hour().minute())
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: start)
        let when: String = if day == today {
            time
        } else if day == calendar.date(byAdding: .day, value: 1, to: today) {
            "\(time) tomorrow"
        } else {
            "\(time) on \(start.formatted(format.weekday(.abbreviated).day().month(.abbreviated)))"
        }
        return "Next hard stop: \(stop.name) at \(when)"
    }

    /// "Weekdays", "Weekends", "Every day", or the days' short names in the calendar's week order.
    private static func days(_ weekdays: Set<Int>, locale: Locale, calendar: Calendar) -> String {
        switch weekdays {
        case [2, 3, 4, 5, 6]: return "Weekdays"
        case [1, 7]: return "Weekends"
        case Set(1...7): return "Every day"
        default:
            var localized = calendar
            localized.locale = locale
            let names = localized.shortWeekdaySymbols
            let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
            return order.filter(weekdays.contains).map { names[$0 - 1] }.joined(separator: ", ")
        }
    }
}
