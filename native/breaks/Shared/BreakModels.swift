import Foundation

enum BreakPhase: String, Codable, CaseIterable, Sendable {
    case focusing
    case headsUp
    case breaking
    case paused
}

enum BreakKind: String, Codable, CaseIterable, Sendable {
    case short
    case long
    case planned
    case manual

    var title: String {
        switch self {
        case .short: "Short break"
        case .long: "Long break"
        case .planned: "Planned break"
        case .manual: "Mindful break"
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
        guard weekdays.contains(calendar.component(.weekday, from: date)) else { return false }

        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let start = startHour * 60 + startMinute
        let end = endHour * 60 + endMinute
        if start <= end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
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
        duration: 10 * 60,
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

struct SmartPauseSettings: Codable, Equatable, Sendable {
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
}

struct BreakRecord: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var startedAt: Date
    var endedAt: Date
    var plannedDuration: TimeInterval
    var kind: BreakKind
    var completed: Bool
    var skipped: Bool

    var actualDuration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
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
    var completedShortBreaks = 0
    var snoozesUsedToday = 0
    var snoozeDay = Calendar.current.startOfDay(for: Date())
    var deliveredHeadsUpFor: Date?
    var deliveredPlannedOccurrences: [String: Date] = [:]
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
        let today = records.filter { $0.startedAt >= startOfDay && $0.startedAt <= now }
        let completed = today.filter { $0.completed && !$0.skipped }
        let skipped = today.filter(\.skipped)
        let focusedDuration = max(0, now.timeIntervalSince(max(startOfDay, snapshot.focusStartedAt)))
        let stretches = today.map { max(0, $0.startedAt.timeIntervalSince(startOfDay)) }
        let longest = max(focusedDuration, stretches.max() ?? 0)
        let sorted = stretches.sorted()
        let median = sorted.isEmpty ? focusedDuration : sorted[sorted.count / 2]
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
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// A VoiceOver-friendly duration such as "4 minutes, 30 seconds".
    var spokenDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = self >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: max(0, self.rounded(.up))) ?? clockDuration
    }
}
