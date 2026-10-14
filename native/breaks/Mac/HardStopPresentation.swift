import Foundation

/// What the Mac shows for hard stops: the warning notice, the full-screen overlay, and the menu bar status. It is
/// worked out from the scheduler's state and settings, the time, and whether a call is running, so the controller
/// and views read only from it and hold no hard-stop rules of their own.
struct HardStopPresentation: Equatable {
    /// Why the hard-stop notice is open.
    enum NoticeSubject: Hashable {
        /// A warning for occurrence `occurrenceKey` of stop `id`. The key, unlike the start, survives a time zone
        /// change, so the warning stays and shows the occurrence's current start.
        case warning(id: UUID, occurrenceKey: Int)
        /// The running stop's extension runs out soon.
        case extensionEnding
    }

    /// The running stop an overlay action applies to: its occurrence and its end. A confirmation is for this stop
    /// only, so it lapses when another stop takes the screen or a merged stop moves the end.
    struct StopContext: Hashable {
        var id: UUID
        var occurrenceKey: Int
        var endsAt: Date?
    }

    enum OverlayAction: Hashable {
        case extend(minutes: Int)
        case dismiss

        var title: String {
            switch self {
            case .extend(let minutes): "Extend \(minutes) min"
            case .dismiss: "Dismiss"
            }
        }
    }

    struct Notice: Equatable {
        var name: String
        /// "Hard stop at <time>, in <countdown>", shown on its own line so a long name never hides it.
        var timing: String
        var spokenTitle: String
        /// "Starts when your call ends" while the stop waits for a call.
        var detail: String?
        /// Whether **Start now** is offered. The notice can always be closed; it never offers Snooze or Skip.
        var canStartNow: Bool

        /// "<name> — hard stop at <time>, in <countdown>".
        var title: String { "\(name) — \(timing.lowercasedFirst)" }
    }

    struct Overlay: Equatable {
        var context: StopContext
        var name: String
        /// "Until <time>" or "Until you dismiss it".
        var until: String
        /// Time left until the scheduled end; nil for a stop that lasts until dismissed.
        var remaining: TimeInterval?
        /// Shown only when the escape hatch allows extensions.
        var extensionsLeft: String?
        /// Only what the escape hatch allows right now.
        var actions: [OverlayAction]
    }

    struct MenuBar: Equatable {
        var text: String
        var symbol: String
        var statusLine: String
    }

    /// The notice before an extension runs out appears this long before it does.
    static let extensionWarningLead: TimeInterval = 60
    static let callWaitDetail = "Starts when your call ends"

    var notice: Notice?
    var overlay: Overlay?
    var menuBar: MenuBar?

    init(scheduler: BreakScheduler, noticeSubject: NoticeSubject?, inCall: Bool, now: Date, locale: Locale = .autoupdatingCurrent) {
        let calendar = scheduler.calendar
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        func time(_ date: Date) -> String { date.formatted(style) }

        let snapshot = scheduler.snapshot
        // As the operations see it: a stop that started inside the running one is merged, even before a tick.
        let active = scheduler.activeHardStop(now: now)
        if let active {
            if let until = active.extendedUntil {
                // Hidden by an extension: the countdown runs to when the stop returns, or ends if that comes first.
                let back = min(until, active.endsAt ?? until)
                let left = max(0, back.timeIntervalSince(now))
                let returns = active.endsAt.map { until < $0 } ?? true
                menuBar = MenuBar(
                    text: "Extended · \(left.clockDuration)",
                    symbol: "hourglass",
                    statusLine: "\(active.name) extended, \(returns ? "back" : "ends") in \(left.spokenDuration)"
                )
            } else {
                let until = active.endsAt.map { "Until \(time($0))" } ?? "Until you dismiss it"
                var actions: [OverlayAction] = []
                if case .extend(let minutes, _) = active.escapeHatch, scheduler.canExtendHardStop(now: now) {
                    actions.append(.extend(minutes: minutes))
                }
                if scheduler.canDismissHardStop(now: now) { actions.append(.dismiss) }
                var extensionsLeft: String?
                if case .extend(_, let times) = active.escapeHatch {
                    extensionsLeft = switch Self.extensionsLeft(times: times, used: active.ownerExtensionsUsed) {
                    case 0: "No extensions left"
                    case 1: "1 extension left"
                    case let count: "\(count) extensions left"
                    }
                }
                overlay = Overlay(
                    context: StopContext(id: active.id, occurrenceKey: active.occurrenceKey, endsAt: active.endsAt),
                    name: active.name,
                    until: until,
                    remaining: active.endsAt.map { max(0, $0.timeIntervalSince(now)) },
                    extensionsLeft: extensionsLeft,
                    actions: actions
                )
                menuBar = MenuBar(
                    text: active.endsAt.map { "Hard stop · until \(time($0))" } ?? "Hard stop",
                    symbol: "hand.raised.fill",
                    statusLine: "\(active.name), \(until.lowercasedFirst)"
                )
            }
        } else if let waiting = Self.earliestWaitingStop(scheduler) {
            menuBar = MenuBar(text: "Hard stop · after call", symbol: "phone.fill", statusLine: "\(waiting.name) starts when your call ends")
        }

        switch noticeSubject {
        case .warning(let id, let key):
            guard let stop = scheduler.settings.hardStops.first(where: { $0.id == id && $0.isEnabled }),
                  let occurrence = scheduler.hardStopOccurrence(stop, key: key),
                  !(snapshot.handledHardStops[id.uuidString].map { key <= $0 } ?? false) else { break }
            let startsAt = occurrence.start
            // While a stop runs, a warning applies only to a stop that starts once it has ended; one that starts
            // inside it joins it instead.
            guard active.map({ startsAt >= $0.endsAt ?? .distantFuture }) ?? true else { break }
            let waitsForCall = snapshot.hardStopsWaitingForCall[id.uuidString] == key
                || (inCall && stop.duringCalls == .waitForCallToEnd)
            // Past its start, a stop that is not waiting for a call starts on the next tick.
            guard startsAt > now || waitsForCall else { break }
            notice = Self.notice(
                name: stop.name, at: time(startsAt), startsIn: startsAt.timeIntervalSince(now),
                detail: waitsForCall ? Self.callWaitDetail : nil,
                canStartNow: scheduler.canStartHardStopEarly(id: id, occurrenceKey: key, now: now)
            )
        case .extensionEnding:
            // Once the extension or the stop's end has passed, the next tick shows or ends the stop, so the notice
            // no longer applies.
            guard let active, let until = active.extendedUntil, now < until,
                  active.endsAt.map({ until < $0 && now < $0 }) ?? true else { break }
            notice = Self.notice(
                name: active.name, at: time(until), startsIn: until.timeIntervalSince(now),
                detail: "Your extension is almost over", canStartNow: scheduler.canEndHardStopExtension(now: now)
            )
        case nil:
            break
        }
    }

    /// The stop the user is held for while no stop runs: of the enabled stops waiting for a call, the one whose waiting
    /// occurrence started first. The wait of a stop that was turned off or rescheduled is dropped by the next tick and is not shown meanwhile.
    private static func earliestWaitingStop(_ scheduler: BreakScheduler) -> HardStop? {
        var earliest: (stop: HardStop, start: Date)?
        for stop in scheduler.settings.hardStops where stop.isEnabled {
            guard let start = scheduler.waitingOccurrence(of: stop)?.start else { continue }
            if earliest.map({ start < $0.start }) ?? true { earliest = (stop, start) }
        }
        return earliest?.stop
    }

    /// When the notice before the running stop's extension runs out is due at `now`, the time the extension ends;
    /// otherwise nil. An extension that outlasts the stop's end gets none, since the stop ends instead of coming back.
    static func extensionWarningDue(_ scheduler: BreakScheduler, now: Date) -> Date? {
        guard let active = scheduler.activeHardStop(now: now), let until = active.extendedUntil,
              active.endsAt.map({ until < $0 }) ?? true,
              now < until, until.timeIntervalSince(now) <= extensionWarningLead else { return nil }
        return until
    }

    /// Extensions left of `times`, from 0 to `times`. The counts come from the saved snapshot, so out-of-range values
    /// are clamped instead of trusted.
    static func extensionsLeft(times: Int, used: Int) -> Int {
        let allowed = max(0, times)
        return allowed - min(max(0, used), allowed)
    }

    /// Where the notice panel sits. A hard-stop notice that comes due while the full-screen overlay is up is placed
    /// above it, so its warning is seen at its warning time; otherwise, and always for the regular heads-up, it floats
    /// above other apps' windows only.
    enum NoticeLayer: Equatable {
        case floating
        case aboveOverlay
    }

    static func noticeLayer(showsHardStopNotice: Bool, overlayVisible: Bool) -> NoticeLayer {
        showsHardStopNotice && overlayVisible ? .aboveOverlay : .floating
    }

    /// The hard-stop screen a break-screen window shows: the running stop's, or, while the window fades out after the
    /// stop ended or was dismissed, its last one, so the fading screen never shows regular-break content. Nil shows the
    /// regular break.
    static func overlayScreen(current: Overlay?, last: Overlay?, isClosing: Bool) -> Overlay? {
        current ?? (isClosing ? last : nil)
    }

    /// How late a tick may report a stop's end and still chime: well past the timer's one-second ticks, far short of
    /// a gap worth noticing.
    static let endChimeTolerance: TimeInterval = 60

    /// Whether a stop's end plays the completion chime: only an end reached while the Mac was awake and the app ran,
    /// reported by a tick soon after `scheduledEnd`. `sleptAt` is when the Mac last went to sleep, kept until the first
    /// tick after the wake has run, so an end at or after it passed during the sleep and ends silently, however soon
    /// the wake comes and whether the timer or the wake notice reports it. An end reported by the first tick after a
    /// launch is silent too, like a regular break that ran out then.
    static func chimesOnEnd(
        _ reason: HardStopEndReason, scheduledEnd: Date?, now: Date, sleptAt: Date?, afterRelaunch: Bool
    ) -> Bool {
        guard reason == .ended, !afterRelaunch else { return false }
        if let sleptAt, scheduledEnd.map({ $0 >= sleptAt }) ?? true { return false }
        return scheduledEnd.map { now.timeIntervalSince($0) <= endChimeTolerance } ?? true
    }

    /// Runs a confirmed Extend or Dismiss, only while the overlay at `now` still shows that action for that stop, so a
    /// confirmation never applies to another stop or another extension length. Returns the scheduler's events.
    static func perform(
        _ target: HardStopConfirmation.Target, on scheduler: inout BreakScheduler, now: Date
    ) -> [BreakScheduler.Event] {
        guard let overlay = HardStopPresentation(scheduler: scheduler, noticeSubject: nil, inCall: false, now: now).overlay,
              overlay.context == target.context, overlay.actions.contains(target.action) else { return [] }
        return switch target.action {
        case .extend: scheduler.extendHardStop(now: now)
        case .dismiss: scheduler.dismissHardStop(now: now)
        }
    }

    private static func notice(name: String, at time: String, startsIn: TimeInterval, detail: String?, canStartNow: Bool) -> Notice {
        let ahead = startsIn > 0
        return Notice(
            name: name,
            timing: ahead ? "Hard stop at \(time), in \(startsIn.clockDuration)" : "Hard stop at \(time)",
            spokenTitle: ahead ? "\(name), hard stop at \(time), in \(startsIn.spokenDuration)" : "\(name), hard stop at \(time)",
            detail: detail,
            canStartNow: canStartNow
        )
    }
}

/// Confirms an Extend or Dismiss before it runs. With the pointer, the button is held for `holdDuration`; with the
/// keyboard or VoiceOver, the button is activated and then **Confirm** within `confirmWindow`. A pure value, driven
/// by the overlay with the current time. Each confirmation is for one action on one stop, and lapses when the
/// overlay stops offering it.
struct HardStopConfirmation: Equatable {
    struct Target: Hashable {
        var context: HardStopPresentation.StopContext
        var action: HardStopPresentation.OverlayAction
    }

    static let holdDuration: TimeInterval = 3
    static let confirmWindow: TimeInterval = 5
    /// How late after `holdDuration` a hold can still confirm. Later means the app was suspended during the hold (a
    /// sleep it may not have heard of yet), so the hold lapses.
    static let holdLateness: TimeInterval = 2

    enum State: Equatable {
        case idle
        case holding(Target, since: Date)
        case awaitingConfirm(Target, until: Date)
    }

    private(set) var state: State = .idle
    /// The host's sleep count when the hold began.
    private var holdSleeps = 0

    /// The action being held or awaiting **Confirm**.
    var pending: Target? {
        switch state {
        case .idle: nil
        case .holding(let target, _), .awaitingConfirm(let target, _): target
        }
    }

    /// The pointer went down on the button for `target`. `sleeps` counts the times the Mac went to sleep; the hold
    /// lapses if it changes before the hold confirms.
    mutating func pressBegan(_ target: Target, at now: Date, sleeps: Int) {
        state = .holding(target, since: now)
        holdSleeps = sleeps
    }

    /// The pointer was released or left the button. Returns the target when the hold lasted long enough, without a
    /// sleep, and `update(now:sleeps:)` has not already returned it.
    mutating func pressEnded(at now: Date, sleeps: Int) -> Target? {
        guard case .holding(let target, let since) = state else { return nil }
        state = .idle
        return holdCompletes(since: since, now: now, sleeps: sleeps) ? target : nil
    }

    /// The system cancelled the press (an interrupted drag) or the Mac went to sleep during it. Drops the hold without
    /// running it, however long it lasted, so only a continuous hold that ends by itself or by a release confirms. A
    /// pending **Confirm** is not a press and stays.
    mutating func pressCancelled() {
        if case .holding = state { state = .idle }
    }

    /// Returns the target whose hold has lasted long enough while still held, once. A hold cut by a sleep, or one whose
    /// deadline comes far too late, lapses instead, whatever order the host hears of the sleep in. Also closes an
    /// expired confirm window.
    mutating func update(now: Date, sleeps: Int) -> Target? {
        switch state {
        case .holding(let target, let since) where sleeps != holdSleeps || now.timeIntervalSince(since) >= Self.holdDuration:
            state = .idle
            return holdCompletes(since: since, now: now, sleeps: sleeps) ? target : nil
        case .awaitingConfirm(_, let until) where now >= until:
            state = .idle
        default:
            break
        }
        return nil
    }

    /// The keyboard or VoiceOver activated the button for `target`: the first of two steps.
    mutating func activate(_ target: Target, at now: Date) {
        state = .awaitingConfirm(target, until: now.addingTimeInterval(Self.confirmWindow))
    }

    /// **Confirm** was activated. Returns the target when it came within the confirm window.
    mutating func confirm(at now: Date) -> Target? {
        guard case .awaitingConfirm(let target, let until) = state else { return nil }
        state = .idle
        return now < until ? target : nil
    }

    /// Drops a hold or a pending **Confirm** that the overlay no longer offers: another stop took the screen, the end
    /// moved, or the action changed or went away. Returns true when it dropped one.
    @discardableResult
    mutating func keep(only overlay: HardStopPresentation.Overlay?) -> Bool {
        guard let pending else { return false }
        if let overlay, overlay.context == pending.context, overlay.actions.contains(pending.action) { return false }
        state = .idle
        return true
    }

    mutating func cancel() {
        state = .idle
    }

    private func holdCompletes(since: Date, now: Date, sleeps: Int) -> Bool {
        let held = now.timeIntervalSince(since)
        return sleeps == holdSleeps && held >= Self.holdDuration && held <= Self.holdDuration + Self.holdLateness
    }

    /// From 0 to 1 while `target` is held, otherwise 0.
    func holdProgress(of target: Target, now: Date) -> Double {
        guard case .holding(target, let since) = state else { return 0 }
        return min(1, max(0, now.timeIntervalSince(since) / Self.holdDuration))
    }

    /// Whole seconds left to confirm, or nil when no confirmation is pending.
    func confirmSecondsLeft(now: Date) -> Int? {
        guard case .awaitingConfirm(_, let until) = state, now < until else { return nil }
        return Int(until.timeIntervalSince(now).rounded(.up))
    }
}

/// The pointer side of a hold button: turns drag updates into a press that begins, ends or is cancelled. A press
/// begins only when the first update is over the button. Leaving the button ends the press, and returning to it does
/// not start another. The drag ending or being cancelled resets it, so the next drag is a new press.
struct HoldPress: Equatable {
    enum Change: Equatable {
        case began
        /// Released or left the button: the hold confirms if it lasted long enough.
        case ended
        /// Interrupted: the hold never confirms.
        case cancelled
    }

    private(set) var isTracking = false
    private(set) var isPressed = false

    /// The drag moved, with the pointer over the button (`inside`) or not.
    mutating func changed(inside: Bool) -> Change? {
        if !isTracking {
            isTracking = true
            isPressed = inside
            return inside ? .began : nil
        }
        guard isPressed, !inside else { return nil }
        isPressed = false
        return .ended
    }

    /// The pointer was released.
    mutating func ended() -> Change? {
        defer { self = HoldPress() }
        return isPressed ? .ended : nil
    }

    /// The drag was cancelled without a release.
    mutating func cancelled() -> Change? {
        defer { self = HoldPress() }
        return isPressed ? .cancelled : nil
    }
}

/// The hard-stop notices waiting for the panel, which shows one at a time: the notice before an extension runs out
/// first, then warnings by start time. A notice that is closed, or no longer applies, gives way to the next one, so a
/// warning that arrives while another notice is open, or while a stop covers the screen, is shown later instead of
/// being lost.
struct HardStopNoticeQueue: Equatable {
    typealias Subject = HardStopPresentation.NoticeSubject

    private(set) var subjects: [Subject] = []
    /// The current waits for a call, as of the last `addWaits`.
    private var waits: Set<Subject> = []
    /// The current waits whose notice the user closed.
    private var closedWaits: Set<Subject> = []
    /// The notice the panel showed after the last prune.
    private var presented: Subject?

    /// The notice the panel shows.
    var shown: Subject? { subjects.first }

    /// Adds a notice. A later warning time for the same occurrence shows it again.
    mutating func add(_ subject: Subject) {
        subjects.removeAll { $0 == subject }
        subjects.append(subject)
        subjects.sort { Self.order($0) < Self.order($1) }
    }

    /// Queues the notice of each enabled stop waiting for a call, unless the user closed it during this wait. Its
    /// start has passed, so no warning comes for it, and without the notice it could not be started now. Run after
    /// every tick, it covers a wait restored after a relaunch, one the first tick creates, one that begins while the
    /// app runs, and one whose notice was pruned while another stop ran. One closed before quitting comes back once,
    /// like a warning.
    mutating func addWaits(of scheduler: BreakScheduler) {
        waits = Set(scheduler.settings.hardStops.compactMap { stop -> Subject? in
            guard stop.isEnabled, let key = scheduler.snapshot.hardStopsWaitingForCall[stop.id.uuidString] else { return nil }
            return .warning(id: stop.id, occurrenceKey: key)
        })
        closedWaits.formIntersection(waits)
        waits.subtracting(closedWaits).subtracting(subjects).forEach { add($0) }
    }

    /// The shown notice was closed. A wait's notice stays closed until the wait ends.
    mutating func closeShown() {
        guard let closed = subjects.first else { return }
        subjects.removeFirst()
        if waits.contains(closed) { closedWaits.insert(closed) }
    }

    /// Drops every notice that no longer applies: its stop started, was missed, removed or disabled, or will join
    /// the running stop; or the extension it warns about ended. A wait's notice dropped while another stop runs is
    /// queued again by `addWaits` and kept once it applies. Returns true when the panel now shows a notice it did not
    /// show after the last prune, so the panel comes to the front once, not on every tick.
    @discardableResult
    mutating func prune(scheduler: BreakScheduler, inCall: Bool, now: Date) -> Bool {
        subjects.removeAll {
            HardStopPresentation(scheduler: scheduler, noticeSubject: $0, inCall: inCall, now: now).notice == nil
        }
        defer { presented = shown }
        return shown != nil && shown != presented
    }

    /// Occurrence keys are the local start day and time as `yyyyMMddHHmm`, so they order warnings by start.
    private static func order(_ subject: Subject) -> Int {
        switch subject {
        case .extensionEnding: .min
        case .warning(_, let key): key
        }
    }
}

/// A regular heads-up that a hard-stop notice displaced: one held back because a hard-stop notice was open when it came
/// due, or one on screen when a hard-stop notice took the panel. It comes back once, when the last hard-stop notice
/// closes, if its break is still coming. A heads-up the user dismissed, or one withdrawn by its break, stays hidden.
struct DisplacedHeadsUp: Equatable {
    private(set) var isHeld = false

    /// A heads-up came due. Returns whether to show it now; while a hard-stop notice is open it is held back instead.
    mutating func headsUpDue(hardStopNoticeOpen: Bool) -> Bool {
        isHeld = hardStopNoticeOpen
        return !hardStopNoticeOpen
    }

    /// A hard-stop notice takes the panel, from the regular heads-up when that is on screen.
    mutating func hardStopNoticeShown(regularHeadsUpVisible: Bool) {
        if regularHeadsUpVisible { isHeld = true }
    }

    /// The heads-up was dismissed, or cancelled, or its break started, was snoozed or skipped.
    mutating func withdraw() {
        isHeld = false
    }

    /// The last hard-stop notice closed. Returns whether to bring the heads-up back.
    mutating func restore(stillDue: Bool) -> Bool {
        defer { isHeld = false }
        return isHeld && stillDue
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
