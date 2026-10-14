import Foundation

enum BreakPhase: String, Codable, CaseIterable, Sendable {
    case focusing
    case headsUp
    case breaking
    case paused
}

/// Why reminders are paused. Only a manual pause waits for the user; every other reason resumes on its own.
enum PauseReason: String, Codable, CaseIterable, Sendable {
    case manual
    case idle
    case focus
    case meeting
    case media
    case app
    case game

    var isAutomatic: Bool { self != .manual }

    /// Reasons that come from a live activity signal and resume after the smart-pause grace period.
    var isSmartPause: Bool {
        switch self {
        case .meeting, .media, .app, .game: true
        case .manual, .idle, .focus: false
        }
    }

    var title: String {
        switch self {
        case .manual: "Paused"
        case .idle: "Away from the computer"
        case .focus: "Focus is on"
        case .meeting: "Microphone or camera in use"
        case .media: "An app is keeping the display awake"
        case .app: "A pause app is in front"
        case .game: "A game is in front"
        }
    }
}

enum BreakKind: String, Codable, CaseIterable, Sendable {
    case short
    case long
    case planned
    case manual
    case hardStop

    var title: String {
        switch self {
        case .short: "Short break"
        case .long: "Long break"
        case .planned: "Planned break"
        case .manual: "Mindful break"
        case .hardStop: "Hard stop"
        }
    }
}

enum DisciplineLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case casual
    case balanced
    case hardcore

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var caption: String {
        switch self {
        case .casual: "Skip anytime"
        case .balanced: "Skip after a pause"
        case .hardcore: "No skips allowed"
        }
    }
}

enum BreakBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case ambient
    case aurora
    case dusk
    case classic
    case custom

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ReminderPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeading
    case top
    case topTrailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeading: "Top left"
        case .top: "Top center"
        case .topTrailing: "Top right"
        }
    }
}

struct OfficeHours: Codable, Equatable, Sendable {
    var isEnabled = true
    var startHour = 8
    var startMinute = 0
    var endHour = 20
    var endMinute = 0
    /// Calendar weekday values, where Sunday is 1 and Saturday is 7.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return true }
        let weekday = calendar.component(.weekday, from: date)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let start = startHour * 60 + startMinute
        let end = endHour * 60 + endMinute
        if start <= end {
            return weekdays.contains(weekday) && minute >= start && minute < end
        }
        // An overnight window belongs to the day it starts on: after midnight, check the previous weekday.
        if minute >= start { return weekdays.contains(weekday) }
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        return minute < end && weekdays.contains(previousWeekday)
    }
}

struct PlannedBreak: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var symbol: String
    var hour: Int
    var minute: Int
    var duration: TimeInterval
    var weekdays: Set<Int>
    var isEnabled: Bool

    static let sample = PlannedBreak(
        name: "Afternoon walk",
        symbol: "figure.walk",
        hour: 16,
        minute: 0,
        duration: 15 * 60,
        weekdays: [2, 3, 4, 5, 6],
        isEnabled: true
    )

    func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        isEnabled && weekdays.contains(calendar.component(.weekday, from: date))
    }

    func occurrence(on date: Date, calendar: Calendar = .current) -> Date? {
        guard occurs(on: date, calendar: calendar) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }
}

/// A user-defined time when the screen is blocked until the stop ends, regardless of pauses, office hours,
/// and the regular break schedule.
struct HardStop: Codable, Equatable, Identifiable, Sendable {
    enum End: Codable, Equatable, Sendable {
        /// An end at or before the start time falls on the next day.
        case at(hour: Int, minute: Int)
        case after(TimeInterval)
        case untilDismissed
    }

    enum Repeat: Codable, Equatable, Sendable {
        /// Calendar weekday values, where Sunday is 1 and Saturday is 7. An occurrence belongs to the weekday it starts on.
        case weekdays(Set<Int>)
        /// One occurrence, on this calendar date (year, month, and day). A date rather than an instant, so a time
        /// zone change never moves it to another day.
        case once(DateComponents)

        /// A one-off stop on the calendar day that contains `date`.
        static func once(on date: Date, calendar: Calendar) -> Repeat {
            .once(calendar.dateComponents([.year, .month, .day], from: date))
        }
    }

    enum EscapeHatch: Codable, Equatable, Sendable {
        case none
        /// Hide the stop for `minutes`, up to `times` per occurrence. Its end does not move.
        case extend(minutes: Int, times: Int)
        case dismissEarly
    }

    enum CallBehavior: String, Codable, CaseIterable, Sendable {
        case waitForCallToEnd
        case startAnyway
    }

    static let maximumCount = 20
    static let durationRange: ClosedRange<TimeInterval> = 60...(16 * 3600)
    static let maximumWarnings = 5
    static let warningRange = 1...120
    static let extendMinutesRange = 5...60
    static let extendTimesRange = 1...5

    var id = UUID()
    var name: String
    var isEnabled = true
    var hour: Int
    var minute: Int
    var end: End = .after(30 * 60)
    var repeats: Repeat = .weekdays([2, 3, 4, 5, 6])
    /// Minutes before the start at which a warning is shown.
    var warningMinutes = [10, 2]
    var escapeHatch: EscapeHatch = .extend(minutes: 15, times: 1)
    var duringCalls: CallBehavior = .waitForCallToEnd

    /// The start of the occurrence that begins on the calendar day of `day`, or nil when none does.
    /// When daylight-saving time skips the start minute, the occurrence starts at the next valid minute.
    func start(onDayOf day: Date, calendar: Calendar) -> Date? {
        switch repeats {
        case .weekdays(let weekdays):
            guard weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        case .once(let date):
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard parts.year == date.year, parts.month == date.month, parts.day == date.day else { return nil }
        }
        return Self.time(hour: hour, minute: minute, onDayOf: day, calendar: calendar)
    }

    /// The scheduled end of an occurrence that starts at `start` on its own day, or nil for a stop that lasts until dismissed.
    func end(forStart start: Date, calendar: Calendar) -> Date? {
        end(start: start, onDayOf: start, startHour: hour, startMinute: minute, calendar: calendar)
    }

    /// Whether an `.at` end falls on the next day is decided from the configured clock times, not from the
    /// worked-out start, so a start moved by daylight-saving time does not turn the stop into an overnight one.
    private func end(start: Date, onDayOf day: Date, startHour: Int, startMinute: Int, calendar: Calendar) -> Date? {
        switch end {
        case .untilDismissed:
            return nil
        case .after(let duration):
            return start.addingTimeInterval(duration)
        case .at(let endHour, let endMinute):
            let nextDay = endHour * 60 + endMinute <= startHour * 60 + startMinute
            guard let endDay = calendar.date(byAdding: .day, value: nextDay ? 1 : 0, to: calendar.startOfDay(for: day)),
                  let end = Self.time(hour: endHour, minute: endMinute, onDayOf: endDay, calendar: calendar) else { return nil }
            return max(start, end)
        }
    }

    /// Occurrences that start on the day before, the day of, and the day after `now`, in start order. This covers
    /// every occurrence that can still be running (at most a day long) and every warning (at most 2 hours ahead).
    func occurrences(around now: Date, calendar: Calendar) -> [Occurrence] {
        let today = calendar.startOfDay(for: now)
        return (-1...1).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today).flatMap { occurrence(onDayOf: $0, calendar: calendar) }
        }
    }

    /// The occurrence that begins on the calendar day of `day`, or nil when none does. There is none when
    /// daylight-saving time skips its whole window.
    func occurrence(onDayOf day: Date, calendar: Calendar) -> Occurrence? {
        guard let start = start(onDayOf: day, calendar: calendar) else { return nil }
        let date = calendar.dateComponents([.year, .month, .day], from: day)
        let key = Occurrence.key(year: date.year ?? 0, month: date.month ?? 0, day: date.day ?? 0, hour: hour, minute: minute)
        let end = end(start: start, onDayOf: day, startHour: hour, startMinute: minute, calendar: calendar)
        if let end, end <= start { return nil }
        return Occurrence(start: start, end: end, key: key)
    }

    /// The occurrence identified by `key`, worked out with `calendar` from the day and start time in the key.
    func occurrence(forKey key: Int, calendar: Calendar) -> Occurrence? {
        let parts = Occurrence.parts(of: key)
        guard let day = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)),
              let start = Self.time(hour: parts.hour, minute: parts.minute, onDayOf: day, calendar: calendar) else { return nil }
        return Occurrence(start: start, end: end(start: start, onDayOf: day, startHour: parts.hour, startMinute: parts.minute, calendar: calendar), key: key)
    }

    /// The occurrence identified by `key` when the stop as configured now still has it: on a day it repeats, at its
    /// configured start time, and with a window that daylight-saving time does not skip. Nil once its time or days change.
    func scheduledOccurrence(forKey key: Int, calendar: Calendar) -> Occurrence? {
        let parts = Occurrence.parts(of: key)
        guard let day = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)),
              let occurrence = occurrence(onDayOf: day, calendar: calendar), occurrence.key == key else { return nil }
        return occurrence
    }

    /// True when the occurrence may start at `now`: from its start until its scheduled end. A stop without an end
    /// stays due through the day after it starts, so one missed while the host was off still starts on return.
    func isDue(_ occurrence: Occurrence, now: Date, calendar: Calendar) -> Bool {
        guard occurrence.start <= now else { return false }
        if let end = occurrence.end { return now < end }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return occurrence.start >= yesterday
    }

    /// True for a one-off stop whose occurrence can no longer start.
    func isExpiredOnce(now: Date, calendar: Calendar) -> Bool {
        guard case .once(let date) = repeats else { return false }
        guard let day = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) else { return true }
        guard let occurrence = occurrence(onDayOf: day, calendar: calendar) else {
            return calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
        }
        return occurrence.start <= now && !isDue(occurrence, now: now, calendar: calendar)
    }

    struct Occurrence: Equatable, Sendable {
        var start: Date
        var end: Date?
        /// The occurrence's identity: its local day and configured start time as `yyyyMMddHHmm`. Unlike `start`,
        /// it does not change when the time zone changes, and it orders occurrences of one stop.
        var key: Int

        static func key(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Int {
            (((year * 100 + month) * 100 + day) * 100 + hour) * 100 + minute
        }

        static func parts(of key: Int) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int) {
            (key / 100_000_000, key / 1_000_000 % 100, key / 10_000 % 100, key / 100 % 100, key % 100)
        }
    }

    private static func time(hour: Int, minute: Int, onDayOf day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
}

/// A field of a hard stop that the editor can mark as invalid. `stopID` is nil for an error about the whole list.
struct HardStopFieldError: Equatable, Sendable {
    enum Field: String, Sendable {
        case list
        case name
        case start
        case end
        case repeats
        case warningMinutes
        case escapeHatch
    }

    var stopID: UUID?
    var field: Field
    var message: String
}

enum HardStopEndReason: String, Codable, Sendable {
    case ended
    case dismissed
    /// The stop waited for a call, and its scheduled end passed before the call ended. It never started.
    case missed
}

/// The hard stop that is running (shown, or hidden by an extension). It keeps the rules it started with,
/// so editing or deleting the stop in settings does not change a running occurrence.
struct ActiveHardStop: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// The scheduled start of the occurrence, or when it started if a time zone change moved that start later.
    var occurrence: Date
    /// The occurrence's identity (`HardStop.Occurrence.key`).
    var occurrenceKey: Int
    /// When it actually started; later than `occurrence` after waiting for a call or a late wake.
    var startedAt: Date
    /// Nil until dismissed.
    var endsAt: Date?
    var escapeHatch: HardStop.EscapeHatch
    /// Extensions used while this occurrence's own escape hatch controlled the stop.
    var extensionsUsed = 0
    /// While set, the stop is hidden by an extension until this time.
    var extendedUntil: Date?
    /// Occurrences that joined this one; each is recorded in history when the stop ends. Only ever appended to.
    var merged: [MergedHardStop] = []
    /// The index in `merged` of the occurrence that took over the escape hatch; nil while this one sets it.
    var escapeHatchOwner: Int?
    /// Focus time counted before the stop started, kept for the stretch statistics.
    var focusDuration: TimeInterval?
    /// The start of the last day whose occurrences were checked for merging.
    var mergedThrough: Date?

    /// Extensions used by the occurrence whose escape hatch controls the stop. A takeover brings its own allowance.
    var ownerExtensionsUsed: Int {
        get {
            guard let index = escapeHatchOwner, merged.indices.contains(index) else { return extensionsUsed }
            return merged[index].extensionsUsed ?? 0
        }
        set {
            if let index = escapeHatchOwner, merged.indices.contains(index) {
                merged[index].extensionsUsed = newValue
            } else {
                extensionsUsed = newValue
            }
        }
    }
}

/// An occurrence that joined a running hard stop.
struct MergedHardStop: Codable, Equatable, Sendable {
    var id: UUID
    /// The occurrence's identity (`HardStop.Occurrence.key`).
    var occurrenceKey: Int
    /// When it joined: its own start, or when a call it waited for ended.
    var joinedAt: Date
    /// Its own scheduled end; nil when it lasts until dismissed.
    var endsAt: Date?
    /// Extensions used while its escape hatch controlled the stop. Nil when none were.
    var extensionsUsed: Int?
}

/// The warnings already delivered for one occurrence: every lead time of `minutes` or more.
struct HardStopWarningMark: Codable, Equatable, Sendable {
    /// The occurrence's identity (`HardStop.Occurrence.key`).
    var occurrence: Int
    var minutes: Int
}

struct SmartPauseSettings: Codable, Equatable, Sendable {
    /// iOS: Focus Filter. macOS: unused (no Focus Filter on the Mac target yet).
    var focusMode = true
    var meetingsAndCalls = true
    var mediaPlayback = true
    var calendarEvents = false
    var deepFocusApps = false
    var games = false
    var gracePeriod: TimeInterval = 60
}

struct WellnessSettings: Codable, Equatable, Sendable {
    var postureEnabled = true
    var postureInterval: TimeInterval = 30 * 60
    var blinkEnabled = true
    var blinkInterval: TimeInterval = 10 * 60
    var dimsBackground = true
    var largePresentation = false
}

struct ReminderSettings: Codable, Equatable, Sendable {
    var headsUpEnabled = true
    var headsUpLeadTime: TimeInterval = 60
    var visibleDuration: TimeInterval = 10
    var countdownEnabled = true
    var countdownDuration: TimeInterval = 5
    var overtimeNudgeEnabled = true
    var overtimeShowsWhenPaused = false
    var position: ReminderPosition = .top
}

struct CustomizationSettings: Codable, Equatable, Sendable {
    var background: BreakBackground = .ambient
    var soundName = "Soft chime"
    var soundVolume = 0.65
    var hapticsEnabled = true
    var customBackgroundFilename: String?
    var customSoundFilename: String?
    var messages = [
        "Let your eyes settle somewhere far away.",
        "Drop your shoulders. Unclench your jaw.",
        "Blink slowly and take one deep breath.",
        "Stand up, stretch, and reset."
    ]
}

struct AutomationSettings: Codable, Equatable, Sendable {
    var startShortcutName = ""
    var endShortcutName = ""
    var runStartShortcut = false
    var runEndShortcut = false
}

/// An app that pauses reminders while it is frontmost (macOS).
struct PauseApp: Codable, Equatable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String

    var id: String { bundleID }
}

enum OverlayStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case blur
    case dim

    var id: String { rawValue }
    var title: String { self == .blur ? "Blur" : "Dim" }
}

struct IdleSettings: Codable, Equatable, Sendable {
    var isEnabled = true
    /// Pause the focus timer after this much time without keyboard, mouse, or trackpad input.
    var pauseAfter: TimeInterval = 60
    /// Treat an absence this long as a break and start a fresh focus interval on return.
    var resetAfter: TimeInterval = 5 * 60
}

/// Settings that only the desktop (macOS) target reads. Kept in the shared model so one store and one
/// schema hold every setting; the iOS target ignores them.
struct DesktopSettings: Codable, Equatable, Sendable {
    var idle = IdleSettings()
    var pauseApps: [PauseApp] = []
    var overlayStyle: OverlayStyle = .blur
    var showsMenuBarCountdown = true
}

struct BreakSettings: Codable, Equatable, Sendable {
    var workInterval: TimeInterval = 20 * 60
    var shortBreakDuration: TimeInterval = 20
    var longBreakEnabled = false
    var longBreakDuration: TimeInterval = 5 * 60
    var longBreakFrequency = 3
    var discipline: DisciplineLevel = .balanced
    var snoozesAllowedPerDay = 5
    var allowEarlyEnd = true
    var earlyEndProgress = 0.8
    var screenTimeEnforcement = true
    var shieldEveryAppAndWebsite = true
    var officeHours = OfficeHours()
    var plannedBreaks = [PlannedBreak.sample]
    var reminder = ReminderSettings()
    var smartPause = SmartPauseSettings()
    var wellness = WellnessSettings()
    var customization = CustomizationSettings()
    var automation = AutomationSettings()
    var desktop = DesktopSettings()
    var hardStops: [HardStop] = []
}

extension BreakSettings {
    /// Decodes settings saved by older builds: missing keys fall back to defaults instead of
    /// discarding the user's whole configuration.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BreakSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        workInterval = try value(.workInterval, defaults.workInterval)
        shortBreakDuration = try value(.shortBreakDuration, defaults.shortBreakDuration)
        longBreakEnabled = try value(.longBreakEnabled, defaults.longBreakEnabled)
        longBreakDuration = try value(.longBreakDuration, defaults.longBreakDuration)
        longBreakFrequency = try value(.longBreakFrequency, defaults.longBreakFrequency)
        discipline = try value(.discipline, defaults.discipline)
        snoozesAllowedPerDay = try value(.snoozesAllowedPerDay, defaults.snoozesAllowedPerDay)
        allowEarlyEnd = try value(.allowEarlyEnd, defaults.allowEarlyEnd)
        earlyEndProgress = try value(.earlyEndProgress, defaults.earlyEndProgress)
        screenTimeEnforcement = try value(.screenTimeEnforcement, defaults.screenTimeEnforcement)
        shieldEveryAppAndWebsite = try value(.shieldEveryAppAndWebsite, defaults.shieldEveryAppAndWebsite)
        officeHours = try value(.officeHours, defaults.officeHours)
        plannedBreaks = try value(.plannedBreaks, defaults.plannedBreaks)
        reminder = try value(.reminder, defaults.reminder)
        smartPause = try value(.smartPause, defaults.smartPause)
        wellness = try value(.wellness, defaults.wellness)
        customization = try value(.customization, defaults.customization)
        automation = try value(.automation, defaults.automation)
        desktop = try value(.desktop, defaults.desktop)
        hardStops = try value(.hardStops, defaults.hardStops)
    }

    /// Field errors for the hard-stop editor. Empty when every stop can be saved. A one-off stop whose
    /// occurrence can no longer start at `now` is an error, because the scheduler would remove it.
    func hardStopErrors(now: Date, calendar: Calendar = .current) -> [HardStopFieldError] {
        var errors: [HardStopFieldError] = []
        if hardStops.count > HardStop.maximumCount {
            errors.append(.init(field: .list, message: "Add at most \(HardStop.maximumCount) hard stops."))
        }
        for stop in hardStops {
            func fail(_ field: HardStopFieldError.Field, _ message: String) {
                errors.append(.init(stopID: stop.id, field: field, message: message))
            }
            if stop.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fail(.name, "Enter a name.")
            }
            // Occurrences are worked out only from valid times, so a malformed value is reported, not evaluated.
            var timesAreValid = true
            if !(0...23).contains(stop.hour) || !(0...59).contains(stop.minute) {
                fail(.start, "Choose a valid start time.")
                timesAreValid = false
            }
            switch stop.end {
            case .at(let hour, let minute):
                if !(0...23).contains(hour) || !(0...59).contains(minute) {
                    fail(.end, "Choose a valid end time.")
                    timesAreValid = false
                }
            case .after(let duration):
                if !HardStop.durationRange.contains(duration) {
                    fail(.end, "A hard stop lasts from 1 minute to 16 hours.")
                    timesAreValid = false
                }
            case .untilDismissed:
                break
            }
            switch stop.repeats {
            case .weekdays(let weekdays):
                if weekdays.isEmpty || !weekdays.allSatisfy((1...7).contains) { fail(.repeats, "Choose at least one day.") }
            case .once(let date):
                if !Self.isCalendarDate(date, calendar: calendar) {
                    fail(.repeats, "Choose a date.")
                } else if timesAreValid, stop.isExpiredOnce(now: now, calendar: calendar) {
                    fail(.repeats, "This date and time have passed.")
                }
            }
            if stop.warningMinutes.count > HardStop.maximumWarnings {
                fail(.warningMinutes, "Add at most \(HardStop.maximumWarnings) warnings.")
            } else if !stop.warningMinutes.allSatisfy(HardStop.warningRange.contains) {
                fail(.warningMinutes, "Warn from 1 to 120 minutes before.")
            }
            if case .extend(let minutes, let times) = stop.escapeHatch,
               !HardStop.extendMinutesRange.contains(minutes) || !HardStop.extendTimesRange.contains(times) {
                fail(.escapeHatch, "Extend by 5 to 60 minutes, 1 to 5 times.")
            }
        }
        return errors
    }

    /// True when `date` names a day that exists, such as 28 February but not 30 February.
    private static func isCalendarDate(_ date: DateComponents, calendar: Calendar) -> Bool {
        guard let year = date.year, let month = date.month, let day = date.day, (1...9999).contains(year),
              let resolved = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let parts = calendar.dateComponents([.year, .month, .day], from: resolved)
        return parts.year == year && parts.month == month && parts.day == day
    }
}

struct BreakRecord: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var startedAt: Date
    var endedAt: Date
    var plannedDuration: TimeInterval
    var kind: BreakKind
    var completed: Bool
    var skipped: Bool
    /// Focus time counted before this break (the stretch it ended). Nil for records saved by older builds.
    var focusDuration: TimeInterval?
    /// Hard stops only: how the occurrence ended and how many extensions it used.
    var hardStopEndReason: HardStopEndReason?
    var extensionsUsed: Int?
    /// When the focus stretch ended, if not at `startedAt`. A missed hard stop's stretch runs until it was missed.
    var focusEndedAt: Date?

    /// The most records kept on the device.
    static let historyLimit = 400

    var actualDuration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    /// The occurrence belongs to the day of `startedAt`; its focus stretch belongs to the day of this time.
    var focusEnd: Date { focusEndedAt ?? startedAt }
}

struct EngineSnapshot: Codable, Equatable, Sendable {
    var phase: BreakPhase = .focusing
    var focusStartedAt = Date()
    var nextBreakAt = Date().addingTimeInterval(20 * 60)
    var pausedRemaining: TimeInterval?
    var breakStartedAt: Date?
    var breakEndsAt: Date?
    var activeKind: BreakKind?
    var activePlannedBreakName: String?
    /// Short breaks completed since the last long break.
    var completedShortBreaks = 0
    var snoozesUsedToday = 0
    var snoozeDay = Calendar.current.startOfDay(for: Date())
    var deliveredHeadsUpFor: Date?
    var deliveredPlannedOccurrences: [String: Date] = [:]
    var pauseReason: PauseReason?
    /// A timed manual pause resumes at this instant.
    var pausedUntil: Date?
    /// The running hard stop, including its extensions; nil when none is running.
    var activeHardStop: ActiveHardStop?
    /// Per hard stop ID: the warnings already delivered for its next occurrence.
    var hardStopWarnings: [String: HardStopWarningMark] = [:]
    /// Per hard stop ID: the key of the latest occurrence that started, merged, ended, or was missed. It and every
    /// earlier occurrence never start again.
    var handledHardStops: [String: Int] = [:]
    /// Per hard stop ID: the key of the due occurrence that is waiting for a call to end.
    var hardStopsWaitingForCall: [String: Int] = [:]
}

extension EngineSnapshot {
    /// Snapshots saved before hard stops existed load with no active stop and no hard-stop progress.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decode(BreakPhase.self, forKey: .phase)
        focusStartedAt = try container.decode(Date.self, forKey: .focusStartedAt)
        nextBreakAt = try container.decode(Date.self, forKey: .nextBreakAt)
        pausedRemaining = try container.decodeIfPresent(TimeInterval.self, forKey: .pausedRemaining)
        breakStartedAt = try container.decodeIfPresent(Date.self, forKey: .breakStartedAt)
        breakEndsAt = try container.decodeIfPresent(Date.self, forKey: .breakEndsAt)
        activeKind = try container.decodeIfPresent(BreakKind.self, forKey: .activeKind)
        activePlannedBreakName = try container.decodeIfPresent(String.self, forKey: .activePlannedBreakName)
        completedShortBreaks = try container.decode(Int.self, forKey: .completedShortBreaks)
        snoozesUsedToday = try container.decode(Int.self, forKey: .snoozesUsedToday)
        snoozeDay = try container.decode(Date.self, forKey: .snoozeDay)
        deliveredHeadsUpFor = try container.decodeIfPresent(Date.self, forKey: .deliveredHeadsUpFor)
        deliveredPlannedOccurrences = try container.decode([String: Date].self, forKey: .deliveredPlannedOccurrences)
        pauseReason = try container.decodeIfPresent(PauseReason.self, forKey: .pauseReason)
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        activeHardStop = try container.decodeIfPresent(ActiveHardStop.self, forKey: .activeHardStop)
        hardStopWarnings = try container.decodeIfPresent([String: HardStopWarningMark].self, forKey: .hardStopWarnings) ?? [:]
        handledHardStops = try container.decodeIfPresent([String: Int].self, forKey: .handledHardStops) ?? [:]
        hardStopsWaitingForCall = try container.decodeIfPresent([String: Int].self, forKey: .hardStopsWaitingForCall) ?? [:]
    }
}

struct DashboardStats: Equatable, Sendable {
    var screenScore: Int
    var focusTime: TimeInterval
    var breaksTaken: Int
    var breakTime: TimeInterval
    var skippedBreaks: Int
    var snoozes: Int
    var longestStretch: TimeInterval
    var typicalStretch: TimeInterval

    static let empty = DashboardStats(
        screenScore: 100,
        focusTime: 0,
        breaksTaken: 0,
        breakTime: 0,
        skippedBreaks: 0,
        snoozes: 0,
        longestStretch: 0,
        typicalStretch: 0
    )
}

enum BreakMath {
    static func stats(records: [BreakRecord], snapshot: EngineSnapshot, now: Date, calendar: Calendar = .current) -> DashboardStats {
        let startOfDay = calendar.startOfDay(for: now)
        let todayRecords = records.filter { $0.startedAt >= startOfDay && $0.startedAt <= now }
        // Hard stops are not breaks: they count toward neither the break statistics nor the skip penalty.
        // The focus stretch that ended at a hard stop still counts as focus time.
        let today = todayRecords.filter { $0.kind != .hardStop }
        let completed = today.filter { $0.completed && !$0.skipped }
        let skipped = today.filter(\.skipped)
        // A stretch is the focus time counted before a break, not the time since midnight. While a hard stop runs
        // (shown or hidden by an extension), the current stretch is the one that ended when it started.
        let currentStretch: TimeInterval
        if let active = snapshot.activeHardStop {
            currentStretch = min(max(0, active.focusDuration ?? 0), max(0, active.startedAt.timeIntervalSince(startOfDay)))
        } else {
            let currentEnd = snapshot.phase == .breaking ? (snapshot.breakStartedAt ?? now) : now
            currentStretch = max(0, currentEnd.timeIntervalSince(max(startOfDay, snapshot.focusStartedAt)))
        }
        // A stretch belongs to the day it ended on and counts only its part since midnight.
        let stretches = records.compactMap { record -> TimeInterval? in
            let focusEnd = record.focusEnd
            guard let focus = record.focusDuration, focusEnd >= startOfDay, focusEnd <= now else { return nil }
            return min(max(0, focus), focusEnd.timeIntervalSince(startOfDay))
        }
        let focusedDuration = stretches.reduce(currentStretch, +)
        let longest = max(currentStretch, stretches.max() ?? 0)
        let sorted = stretches.sorted()
        let median = sorted.isEmpty ? currentStretch : sorted[sorted.count / 2]
        let scorePenalty = skipped.count * 12 + snapshot.snoozesUsedToday * 3 + Int(max(0, longest - 45 * 60) / (15 * 60)) * 4

        return DashboardStats(
            screenScore: max(0, min(100, 100 - scorePenalty)),
            focusTime: focusedDuration,
            breaksTaken: completed.count,
            breakTime: completed.reduce(0) { $0 + $1.actualDuration },
            skippedBreaks: skipped.count,
            snoozes: snapshot.snoozesUsedToday,
            longestStretch: longest,
            typicalStretch: median
        )
    }

    static func nextPlannedBreak(settings: BreakSettings, after date: Date, calendar: Calendar = .current) -> (PlannedBreak, Date)? {
        for dayOffset in 0...7 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            for planned in settings.plannedBreaks where planned.isEnabled {
                guard let occurrence = planned.occurrence(on: candidateDay, calendar: calendar), occurrence > date else { continue }
                return settings.plannedBreaks
                    .compactMap { item -> (PlannedBreak, Date)? in
                        guard let itemOccurrence = item.occurrence(on: candidateDay, calendar: calendar), itemOccurrence > date else { return nil }
                        return (item, itemOccurrence)
                    }
                    .min { $0.1 < $1.1 }
            }
        }
        return nil
    }
}

extension TimeInterval {
    var compactDuration: String {
        let total = max(0, Int(self.rounded()))
        if total < 60 { return "\(total)s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    var clockDuration: String {
        let total = max(0, Int(self.rounded(.up)))
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// A VoiceOver-friendly duration such as "4 minutes, 30 seconds".
    var spokenDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = self >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: max(0, self.rounded(.up))) ?? clockDuration
    }
}
