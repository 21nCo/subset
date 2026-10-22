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

    /// The start of the latest episode the companion offered, recorded only once the panel showed it or macOS accepted
    /// its notification.
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

    /// Records `episode` as offered, once it reached the user: the panel showed it, or macOS accepted its notification
    /// (see `DriftOfferDelivery`).
    public mutating func recordOffer(of episode: DriftEpisode) {
        promptedEpisode = episode.start
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

/// How the companion offers a drift and records it: at once when the panel showed it, else by a notification when the
/// user turned that fallback on. One notification is on its way at a time, and until macOS answers no drift is offered
/// again, so a refresh meanwhile never sends a second one. Just before it is submitted, after the asynchronous permission
/// read, `confirm` checks that the drift is still eligible; once macOS accepted it, `finish` records it, whatever any
/// later read says. A drift that reached the user neither way (no panel and no fallback, no longer eligible at
/// submission, or macOS refused the notification: notifications turned off in System Settings, say) is not recorded and
/// stays eligible. Recording the episode sent can never mark a later one: a reset or a new session moves the next
/// episode's `since` past it.
public struct DriftOfferDelivery: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// The panel showed it, and it was recorded as offered.
        case recorded
        /// Send its notification: pass a fresh decision to `confirm` just before submitting it, then macOS's answer to
        /// `finish`.
        case sendNotification
        /// Nothing reached the user; a later refresh offers it again.
        case notDelivered
    }

    /// The drift whose notification is on its way: being confirmed, or submitted and not answered yet.
    public private(set) var sending: DriftEpisode?

    public init() {}

    public var isSending: Bool { sending != nil }

    /// Offers `episode`, after the companion tried the panel: `panelShown` says whether it appeared.
    public mutating func offer(_ episode: DriftEpisode, panelShown: Bool, fallbackEnabled: Bool, state: inout CompanionState) -> Step {
        if panelShown {
            state.recordOffer(of: episode)
            return .recorded
        }
        guard fallbackEnabled, sending == nil else { return .notDelivered }
        sending = episode
        return .sendNotification
    }

    /// Just before the notification is submitted: `current` is the decision from a fresh read with the current rule and
    /// state (`.none` while capture is not recording or the read failed), and `fallbackEnabled` the fallback setting
    /// now. Returns the episode to submit, the drift sent as it stands now (it may have grown), when it is still offered
    /// as a prompt in the same run and the fallback is still on. Otherwise nothing is submitted or recorded and the
    /// delivery ends: returns nil.
    public mutating func confirm(current: DriftDecision, fallbackEnabled: Bool) -> DriftEpisode? {
        guard let sent = sending else { return nil }
        guard fallbackEnabled, case .prompt(let episode) = current, episode.since <= sent.start else {
            sending = nil
            return nil
        }
        sending = episode
        return episode
    }

    /// macOS's answer for the notification submitted. When it accepted it, records the episode sent in `state`: it
    /// reached the user. Returns whether it did.
    public mutating func finish(accepted: Bool, state: inout CompanionState) -> Bool {
        guard let sent = sending else { return false }
        sending = nil
        guard accepted else { return false }
        state.recordOffer(of: sent)
        return true
    }
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

/// What the app gives the drift companion's flow: its settings and record, the store, capture, the panel, and the
/// notification fallback.
@MainActor
public protocol DriftCompanionHost: AnyObject {
    var companionState: CompanionState { get set }
    var driftRule: DriftRule { get }
    var notificationFallback: Bool { get }
    /// Whether capture is recording; nothing is offered otherwise.
    var isRecording: Bool { get }
    /// Reads the blocks since the start of today or the last day, whichever is earlier, and updates the ring; nil when
    /// the store cannot be read.
    func readBlocks(now: Date) -> (blocks: [Block], from: Date)?
    /// Shows the panel with the flow's `onOffer` and `actionError`; false when there is nowhere to show it.
    func showPanel() -> Bool
    func closePanel()
    /// Sends the notification for the drift in the flow's `delivery.sending`: asks `confirmSubmission` just before
    /// submitting it, then passes macOS's answer to `deliveryAnswered`.
    func sendDriftNotification()
    /// Reports by notification that Not a Drift was not fully saved.
    func sendFailureNotification(_ message: String)
    /// Take a Break: pauses tracking until `end`. This may refresh the flow synchronously.
    func pauseTracking(until end: Date, at now: Date)
    /// Not a Drift: labels each block `label` through the store's correction operation, then recounts classification,
    /// which may refresh the flow synchronously. Returns why each block that was not corrected was not.
    func relabel(_ blockStarts: [Date], as label: BlockLabel, at now: Date) -> [String]
    /// Something the menu bar item shows changed.
    func companionChanged()
}

/// The drift companion's steps, ordered so a drift recorded as offered is always one the user can act on. A refresh
/// offers a new drift only while no action is running and the panel is not holding an episode or an action's error.
/// An action's own effects ask for refreshes synchronously (a correction recounts classification, a pause changes the
/// capture state); those wait until the action has closed the panel or shown its error, and then one refresh runs. So
/// an action never closes or replaces a drift a refresh has just shown and recorded, and a drift held back meanwhile is
/// not recorded and stays eligible.
@MainActor
public final class DriftCompanionFlow {
    public weak var host: (any DriftCompanionHost)?
    /// The episode the panel shows; nil while it is closed.
    public private(set) var onOffer: DriftEpisode?
    /// Why the last action could not finish, shown with the panel.
    public private(set) var actionError: String?
    public private(set) var delivery = DriftOfferDelivery()
    private let calendar: Calendar
    private var acting = false

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    /// Reads the store once, updates the ring, and offers a newly confirmed drift. Nothing is offered unless capture is
    /// recording: a drift noticed while paused, idle, asleep, or locked waits, and is offered only if it is still
    /// current once recording resumes. Nor while the panel is open or a drift notification waits for macOS's answer.
    public func refresh(now: Date) {
        guard let host, !acting else { return }
        defer { host.companionChanged() }
        guard let (blocks, from) = host.readBlocks(now: now) else { return }
        var state = host.companionState
        if state.forgetOfferedEpisode(unlessIn: blocks, readFrom: from) { host.companionState = state }
        guard onOffer == nil, host.isRecording, !delivery.isSending,
              case .prompt(let episode) = DriftDetector.evaluate(blocks, now: now, rule: host.driftRule, state: state, calendar: calendar)
        else { return }
        offer(episode, host: host)
    }

    /// Shows `episode` in the panel and records it as offered, else sends it as a notification when the user turned that
    /// on, recorded once macOS accepts it. A drift neither reached is not recorded, so a later refresh offers it again.
    private func offer(_ episode: DriftEpisode, host: any DriftCompanionHost) {
        onOffer = episode
        actionError = nil
        let shown = host.showPanel()
        if !shown { onOffer = nil }
        var state = host.companionState
        switch delivery.offer(episode, panelShown: shown, fallbackEnabled: host.notificationFallback, state: &state) {
        case .recorded: host.companionState = state
        case .sendNotification: host.sendDriftNotification()
        case .notDelivered: break
        }
    }

    /// Closes the panel without acting; the episode stays offered, so it is not offered again.
    public func dismiss() {
        onOffer = nil
        actionError = nil
        host?.closePanel()
        host?.companionChanged()
    }

    /// Runs an action's steps, then one refresh; refreshes asked for meanwhile do nothing (see the type's comment).
    private func act(now: Date, _ steps: (any DriftCompanionHost) -> Void) {
        guard let host else { return }
        guard !acting else { return steps(host) }
        acting = true
        steps(host)
        acting = false
        refresh(now: now)
    }

    /// Return to Focus: closes the panel and records a 25-minute focus window, during which no drift is offered and
    /// blocks are not counted toward one.
    public func returnToFocus(at now: Date) {
        act(now: now) { host in
            var state = host.companionState
            state.returnToFocus(at: now)
            host.companionState = state
            dismiss()
        }
    }

    /// Ends the focus window early, from the menu.
    public func endFocusWindow(at now: Date) {
        act(now: now) { host in
            var state = host.companionState
            state.endFocusWindow(at: now)
            host.companionState = state
        }
    }

    /// Take a Break: holds back drift prompts for `length`, pauses tracking, and closes the panel.
    public func takeBreak(for length: TimeInterval, at now: Date) {
        act(now: now) { host in
            var state = host.companionState
            let end = state.takeBreak(for: length, at: now)
            host.companionState = state
            host.pauseTracking(until: end, at: now)
            dismiss()
        }
    }

    /// Not a Drift: relabels the episode's blocks. If any block could not be corrected (one deleted meanwhile, say), the
    /// others keep their correction and the panel shows the error for the episode, opening again when the action came
    /// from the menu or a notification; when it cannot be shown, a notification reports it if the fallback is allowed.
    /// While that error is on screen no new drift is offered. A panel offering another drift (the action came from an
    /// older notification) stays as it is, and an error is reported by notification.
    public func notADrift(_ episode: DriftEpisode, as label: BlockLabel, at now: Date) {
        act(now: now) { host in
            let panelOffersAnother = onOffer.map { $0 != episode } ?? false
            let failures = host.relabel(episode.blockStarts, as: label, at: now)
            guard !failures.isEmpty else {
                if !panelOffersAnother { dismiss() }
                return
            }
            let message = "Could not relabel every block. " + failures.joined(separator: "; ")
            if !panelOffersAnother {
                onOffer = episode
                actionError = message
                guard !host.showPanel() else { return }
                onOffer = nil
            }
            if host.notificationFallback { host.sendFailureNotification(message) }
        }
    }

    /// After the user changed a drift setting: turning the companion off closes the panel.
    public func settingsChanged(at now: Date) {
        act(now: now) { host in
            if !host.driftRule.enabled { dismiss() }
        }
    }

    /// Just before the drift notification is submitted, after the asynchronous permission read: the episode to submit,
    /// from a fresh read, or nil when it is no longer offered (see `DriftOfferDelivery.confirm`), which leaves it
    /// unrecorded and eligible.
    public func confirmSubmission(now: Date) -> DriftEpisode? {
        guard let host else { return nil }
        let current = host.isRecording ? host.readBlocks(now: now).map {
            DriftDetector.evaluate($0.blocks, now: now, rule: host.driftRule, state: host.companionState, calendar: calendar)
        } ?? .none : .none
        return delivery.confirm(current: current, fallbackEnabled: host.notificationFallback)
    }

    /// macOS's answer for the drift notification submitted: one accepted is recorded as offered, whatever a later read
    /// says; one refused stays eligible, and the next refresh offers it again rather than retrying at once.
    public func deliveryAnswered(accepted: Bool, now: Date) {
        guard let host else { return }
        var state = host.companionState
        if delivery.finish(accepted: accepted, state: &state) { host.companionState = state }
        if accepted { refresh(now: now) } else { host.companionChanged() }
    }
}
