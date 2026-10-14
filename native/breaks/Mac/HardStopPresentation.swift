import Foundation

/// What the Mac shows for hard stops: the warning notice, the full-screen overlay, and the menu bar status. It is
/// worked out from the scheduler's state and settings, the time, and whether a call is running, so the controller
/// and views read only from it and hold no hard-stop rules of their own.
struct HardStopPresentation: Equatable {
    /// Why the hard-stop notice is open.
    enum NoticeSubject: Equatable {
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
        var title: String
        var spokenTitle: String
        /// "Starts when your call ends" while the stop waits for a call.
        var detail: String?
        /// Whether **Start now** is offered. The notice can always be closed; it never offers Snooze or Skip.
        var canStartNow: Bool
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
        } else if let waiting = snapshot.hardStopsWaitingForCall.compactMap({ id, key in
            scheduler.settings.hardStops.first { $0.id.uuidString == id }.flatMap { stop in
                stop.occurrence(forKey: key, calendar: calendar).map { (stop: stop, start: $0.start) }
            }
        }).min(by: { $0.start < $1.start })?.stop {
            // The stop the user is held for: the waiting occurrence that started first.
            menuBar = MenuBar(text: "Hard stop · after call", symbol: "phone.fill", statusLine: "\(waiting.name) starts when your call ends")
        }

        switch noticeSubject {
        case .warning(let id, let key):
            guard let stop = scheduler.settings.hardStops.first(where: { $0.id == id && $0.isEnabled }),
                  let occurrence = stop.occurrence(forKey: key, calendar: calendar),
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
            // Once the stop's end has passed, the next tick ends it, so the notice no longer applies.
            guard let active, let until = active.extendedUntil,
                  active.endsAt.map({ until < $0 && now < $0 }) ?? true else { break }
            notice = Self.notice(
                name: active.name, at: time(until), startsIn: until.timeIntervalSince(now),
                detail: "Your extension is almost over", canStartNow: scheduler.canEndHardStopExtension(now: now)
            )
        case nil:
            break
        }
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

    /// Whether a stop's end plays the completion chime. An end that passed while the app was not running, reported by
    /// the first tick after launch, ends silently, like a regular break that ran out then.
    static func chimesOnEnd(_ reason: HardStopEndReason, afterRelaunch: Bool) -> Bool {
        reason == .ended && !afterRelaunch
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
            title: ahead ? "\(name) — hard stop at \(time), in \(startsIn.clockDuration)" : "\(name) — hard stop at \(time)",
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

    enum State: Equatable {
        case idle
        case holding(Target, since: Date)
        case awaitingConfirm(Target, until: Date)
    }

    private(set) var state: State = .idle

    /// The action being held or awaiting **Confirm**.
    var pending: Target? {
        switch state {
        case .idle: nil
        case .holding(let target, _), .awaitingConfirm(let target, _): target
        }
    }

    /// The pointer went down on the button for `target`.
    mutating func pressBegan(_ target: Target, at now: Date) {
        state = .holding(target, since: now)
    }

    /// The pointer was released or left the button. Returns the target when the hold lasted long enough and
    /// `update(now:)` has not already returned it.
    mutating func pressEnded(at now: Date) -> Target? {
        guard case .holding(let target, let since) = state else { return nil }
        state = .idle
        return now.timeIntervalSince(since) >= Self.holdDuration ? target : nil
    }

    /// Returns the target whose hold has lasted long enough while still held, once. Also closes an expired confirm window.
    mutating func update(now: Date) -> Target? {
        switch state {
        case .holding(let target, let since) where now.timeIntervalSince(since) >= Self.holdDuration:
            state = .idle
            return target
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

/// The hard-stop notices waiting for the panel, which shows one at a time: the notice before an extension runs out
/// first, then warnings by start time. A notice that is closed, or no longer applies, gives way to the next one, so a
/// warning that arrives while another notice is open, or while a stop covers the screen, is shown later instead of
/// being lost.
struct HardStopNoticeQueue: Equatable {
    typealias Subject = HardStopPresentation.NoticeSubject

    private(set) var subjects: [Subject] = []

    /// The notice the panel shows.
    var shown: Subject? { subjects.first }

    /// Adds a notice. A later warning time for the same occurrence shows it again.
    mutating func add(_ subject: Subject) {
        subjects.removeAll { $0 == subject }
        subjects.append(subject)
        subjects.sort { Self.order($0) < Self.order($1) }
    }

    /// The shown notice was closed.
    mutating func closeShown() {
        if !subjects.isEmpty { subjects.removeFirst() }
    }

    /// Drops every notice that no longer applies: its stop started, was missed, removed or disabled, or will join
    /// the running stop; or the extension it warns about ended.
    mutating func prune(scheduler: BreakScheduler, inCall: Bool, now: Date) {
        subjects.removeAll {
            HardStopPresentation(scheduler: scheduler, noticeSubject: $0, inCall: inCall, now: now).notice == nil
        }
    }

    /// Occurrence keys are the local start day and time as `yyyyMMddHHmm`, so they order warnings by start.
    private static func order(_ subject: Subject) -> Int {
        switch subject {
        case .extensionEnding: .min
        case .warning(_, let key): key
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
