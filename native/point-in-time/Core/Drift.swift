import Foundation

// The menu-bar ring and the drift companion's rule: pure functions of stored blocks, the user's drift settings, and
// what the companion has already done, so the app only reads the store, asks, and shows the answer.

extension CategorySeconds {
    /// `category`'s share of classified time (focus, neutral, and drift); nil when nothing is classified. The window's
    /// day rings and the menu-bar ring both use it.
    public func share(of category: TimeCategory) -> Double? {
        classified > 0 ? self[category] / classified : nil
    }
}

/// What the menu-bar ring draws: today's focus, neutral, and drift as shares of classified time, from the day's report
/// totals. With nothing classified the ring is empty, never 0%.
public struct FocusRing: Equatable, Sendable {
    public static let categories: [TimeCategory] = [.focus, .neutral, .drift]

    public let totals: CategorySeconds

    public init(totals: CategorySeconds) {
        self.totals = totals
    }

    /// Today's ring: the totals of today's `DayReport`.
    public init(today now: Date, blocks: [Block], calendar: Calendar) {
        self.init(totals: DayReport(day: now, blocks: blocks, calendar: calendar).totals)
    }

    public var isEmpty: Bool { totals.classified <= 0 }

    /// The arcs in drawing order, each a fraction of the whole ring; they add up to 1. Empty with nothing classified.
    public var arcs: [(category: TimeCategory, fraction: Double)] {
        Self.categories.compactMap { category in
            totals.share(of: category).flatMap { $0 > 0 ? (category, $0) : nil }
        }
    }

    /// What VoiceOver reads for the ring: "Focus 62%, Neutral 20%, Drift 18% today", with the window's rounding.
    public var accessibilityText: String {
        guard !isEmpty else { return "No classified time today" }
        return Self.categories.map { "\($0.title) \(ReportText.percent(totals.share(of: $0) ?? 0))" }.joined(separator: ", ") + " today"
    }
}

/// A daily span of local clock time during which drift is not watched, such as 22:00 to 07:00. A start after its end
/// wraps past midnight; an equal start and end is an empty span.
public struct QuietHours: Equatable, Sendable, Codable {
    /// Minutes after local midnight, 0–1439.
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = Self.clamp(startMinute)
        self.endMinute = Self.clamp(endMinute)
    }

    /// Whether `date`'s local clock time falls in the span, its start included and its end not.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let minute = ReportPeriod.minuteOfDay(date, calendar: calendar)
        if startMinute <= endMinute { return startMinute <= minute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    private static func clamp(_ minute: Int) -> Int { min(max(minute, 0), 1_439) }
}

/// The user's drift settings.
public struct DriftRule: Equatable, Sendable {
    public static let thresholds = 2...5
    public static let defaultThreshold = 2

    public var enabled: Bool
    /// Drift blocks that confirm a drift, kept within `thresholds`.
    public var threshold: Int {
        didSet { threshold = Self.clamp(threshold) }
    }
    public var quietHours: QuietHours?

    public init(enabled: Bool = true, threshold: Int = Self.defaultThreshold, quietHours: QuietHours? = nil) {
        self.enabled = enabled
        self.threshold = Self.clamp(threshold)
        self.quietHours = quietHours
    }

    private static func clamp(_ threshold: Int) -> Int { min(max(threshold, thresholds.lowerBound), thresholds.upperBound) }
}

/// The drift blocks of one episode so far, in start order.
public struct DriftEpisode: Equatable, Sendable {
    /// Where the episode's run began: the session's start, the end of the last block that reset the count, or the end
    /// of the latest focus window or break. A drift offered at or after it is this episode, whichever of the run's
    /// blocks are drift now.
    public var since: Date
    public var blockStarts: [Date]

    /// `blockStarts` must not be empty.
    public init(since: Date, blockStarts: [Date]) {
        precondition(!blockStarts.isEmpty, "An episode holds at least one drift block")
        self.since = since
        self.blockStarts = blockStarts
    }

    public var start: Date { blockStarts[0] }
    public var end: Date { blockStarts[blockStarts.count - 1].addingTimeInterval(Block.length) }
}

/// What the companion has done, kept between launches so an episode is never offered twice.
public struct CompanionState: Equatable, Sendable {
    public static let focusWindowLength: TimeInterval = 25 * 60
    public static let breakLengths: [TimeInterval] = [5 * 60, 10 * 60, 15 * 60]

    /// The start of the latest episode the companion offered, recorded only once it was shown or sent.
    public var promptedEpisode: Date?
    /// The latest focus intent, from Return to Focus.
    public var focusWindow: DateInterval?
    /// The end of the latest break, from Take a Break.
    public var breakUntil: Date?

    public init(promptedEpisode: Date? = nil, focusWindow: DateInterval? = nil, breakUntil: Date? = nil) {
        self.promptedEpisode = promptedEpisode
        self.focusWindow = focusWindow
        self.breakUntil = breakUntil
    }

    /// Prompts are held back until this time, and blocks starting before it never count toward an episode: what the
    /// user did before choosing to focus or rest is settled.
    public var suppressedUntil: Date? {
        [focusWindow?.end, breakUntil].compactMap { $0 }.max()
    }

    public func isSuppressed(at now: Date) -> Bool { suppressedUntil.map { now < $0 } ?? false }

    /// The focus window running at `now`, if any.
    public func activeFocusWindow(at now: Date) -> DateInterval? {
        focusWindow.flatMap { $0.start <= now && now < $0.end ? $0 : nil }
    }

    /// Return to Focus: a 25-minute focus window from `now`.
    public mutating func returnToFocus(at now: Date) {
        focusWindow = DateInterval(start: now, duration: Self.focusWindowLength)
    }

    /// Take a Break: prompts wait until the break ends, which is returned. A later break already set is kept.
    @discardableResult
    public mutating func takeBreak(for length: TimeInterval, at now: Date) -> Date {
        let end = now.addingTimeInterval(length)
        breakUntil = max(breakUntil ?? end, end)
        return end
    }

    /// Records `episode` as offered if `route` delivered it; an undelivered drift stays eligible for the next refresh.
    /// Returns whether it was recorded.
    @discardableResult
    public mutating func recordOffer(of episode: DriftEpisode, by route: DriftOfferRoute) -> Bool {
        guard route.delivers else { return false }
        promptedEpisode = episode.start
        return true
    }

    /// Forgets the drift last offered unless its first block is among `blocks`, read from `readFrom` on: a deletion
    /// removed it, or it is older than the read and can no longer name a current episode. Returns whether it changed.
    public mutating func forgetOfferedEpisode(unlessIn blocks: [Block], readFrom: Date) -> Bool {
        guard let offered = promptedEpisode, offered < readFrom || !blocks.contains(where: { $0.start == offered }) else { return false }
        promptedEpisode = nil
        return true
    }

    /// Ends the focus window now; prompts are allowed again unless a break is still running.
    public mutating func endFocusWindow(at now: Date) {
        guard let window = activeFocusWindow(at: now) else { return }
        focusWindow = DateInterval(start: window.start, end: max(window.start, now))
    }
}

/// How a drift to offer reaches the user: the panel when it could be shown, else a notification when the user turned the
/// fallback on and macOS allows it. Only those two deliver, so a drift that could not be shown is not recorded as
/// offered.
public enum DriftOfferRoute: Equatable, Sendable {
    case panel
    case notification
    /// The fallback is on but macOS has not yet said whether notifications are allowed: offer again once it has.
    case awaitingPermission
    /// Neither can show it now; it is offered again at a later refresh while it is still current.
    case undelivered

    public init(panelShown: Bool, fallbackEnabled: Bool, notificationsAllowed: Bool?) {
        self = if panelShown { .panel }
        else if !fallbackEnabled { .undelivered }
        else if let notificationsAllowed { notificationsAllowed ? .notification : .undelivered }
        else { .awaitingPermission }
    }

    public var delivers: Bool { self == .panel || self == .notification }
}

/// The outcome of checking the current session for a drift.
public enum DriftDecision: Equatable, Sendable {
    /// No confirmed drift: the rule is off, the session is not current, or too few drift blocks.
    case none
    /// A confirmed drift the companion has not offered yet: offer it now.
    case prompt(DriftEpisode)
    /// The confirmed drift was offered already.
    case alreadyPrompted(DriftEpisode)
    /// A confirmed drift during quiet hours or a focus window or break: not offered.
    case suppressed(DriftEpisode)
}

/// The drift confirmation rule.
///
/// - The current session is the latest run of blocks with no missing bucket between them (idle, paused, asleep, or
///   locked for a whole block ends a session), and it is current only while its last block ended no more than one
///   block length before now.
/// - In it, each Drift block counts and any Focus block resets the count. Neutral, unclassified (pending or failed),
///   and excluded-only blocks neither count nor reset. A block's label is the one reports use: the user's correction,
///   else the model's.
/// - A block starting in quiet hours resets the count, so an episode never reaches across them, and blocks starting
///   before the end of the latest focus window or break are not counted.
/// - The drift is confirmed once the count reaches the threshold, and offered at most once per episode: the companion
///   records the first drift block of the episode it offered, and an episode holding that time (no reset since) was
///   offered, even if a correction has since relabeled some of its blocks or an earlier block in the run has since
///   been labeled drift.
/// - Nothing is offered while the rule is off, in quiet hours, or during a focus window or break.
public enum DriftDetector {
    /// The episode the current session's drift blocks form, whatever the threshold; nil with none.
    public static func episode(in blocks: [Block], now: Date, rule: DriftRule, state: CompanionState, calendar: Calendar) -> DriftEpisode? {
        let sorted = blocks.sorted { $0.start < $1.start }
        guard let last = sorted.last, now.timeIntervalSince(last.end) <= Block.length else { return nil }
        var first = sorted.count - 1
        while first > 0, sorted[first - 1].end == sorted[first].start { first -= 1 }
        var since = max(sorted[first].start, state.suppressedUntil ?? .distantPast)
        var starts: [Date] = []
        for block in sorted[first...] where block.start >= since {
            if rule.quietHours?.contains(block.start, calendar: calendar) == true || block.reportLabel == .focus {
                since = block.end
                starts.removeAll()
            } else if block.reportLabel == .drift {
                starts.append(block.start)
            }
        }
        return starts.isEmpty ? nil : DriftEpisode(since: since, blockStarts: starts)
    }

    public static func evaluate(_ blocks: [Block], now: Date, rule: DriftRule, state: CompanionState, calendar: Calendar) -> DriftDecision {
        guard rule.enabled, let episode = episode(in: blocks, now: now, rule: rule, state: state, calendar: calendar),
              episode.blockStarts.count >= rule.threshold else { return .none }
        // The episode is its run, from `since`: a drift offered in it is this one, even if earlier blocks have turned
        // drift since (a backlog classified newest first, a retry, or a correction) and moved its first block back.
        if let offered = state.promptedEpisode, episode.since <= offered { return .alreadyPrompted(episode) }
        if state.isSuppressed(at: now) || rule.quietHours?.contains(now, calendar: calendar) == true { return .suppressed(episode) }
        return .prompt(episode)
    }
}
