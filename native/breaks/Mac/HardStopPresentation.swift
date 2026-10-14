import Foundation

/// What the Mac shows for hard stops: the warning notice, the full-screen overlay, and the menu bar status. It is
/// worked out from the scheduler's state and settings, the time, and whether a call is running, so the controller
/// and views read only from it and hold no hard-stop rules of their own.
struct HardStopPresentation: Equatable {
    /// Why the hard-stop notice is open.
    enum NoticeSubject: Equatable {
        /// A warning for the occurrence of stop `id` that starts at `startsAt`.
        case warning(id: UUID, startsAt: Date)
        /// The running stop's extension runs out soon.
        case extensionEnding
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
        if let active = snapshot.activeHardStop {
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
                    extensionsLeft = switch max(0, times - active.ownerExtensionsUsed) {
                    case 0: "No extensions left"
                    case 1: "1 extension left"
                    case let count: "\(count) extensions left"
                    }
                }
                overlay = Overlay(
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
        } else if let waiting = snapshot.hardStopsWaitingForCall.keys.sorted().compactMap({ key in
            scheduler.settings.hardStops.first { $0.id.uuidString == key }
        }).first {
            menuBar = MenuBar(text: "Hard stop · after call", symbol: "phone.fill", statusLine: "\(waiting.name) starts when your call ends")
        }

        switch noticeSubject {
        case .warning(let id, let startsAt):
            guard snapshot.activeHardStop == nil,
                  let stop = scheduler.settings.hardStops.first(where: { $0.id == id && $0.isEnabled }),
                  let occurrence = stop.occurrences(around: startsAt, calendar: calendar).first(where: { $0.start == startsAt }),
                  !(snapshot.handledHardStops[id.uuidString].map { occurrence.key <= $0 } ?? false) else { break }
            let waitsForCall = snapshot.hardStopsWaitingForCall[id.uuidString] == occurrence.key
                || (inCall && stop.duringCalls == .waitForCallToEnd)
            // Past its start, a stop that is not waiting for a call starts on the next tick.
            guard startsAt > now || waitsForCall else { break }
            notice = Self.notice(
                name: stop.name, at: time(startsAt), startsIn: startsAt.timeIntervalSince(now),
                detail: waitsForCall ? Self.callWaitDetail : nil,
                canStartNow: scheduler.canStartHardStopEarly(id: id, now: now)
            )
        case .extensionEnding:
            guard let active = snapshot.activeHardStop, let until = active.extendedUntil,
                  active.endsAt.map({ until < $0 }) ?? true else { break }
            notice = Self.notice(
                name: active.name, at: time(until), startsIn: until.timeIntervalSince(now),
                detail: "Your extension is almost over", canStartNow: true
            )
        case nil:
            break
        }
    }

    /// When the notice before the running stop's extension runs out is due at `now`, the time the extension ends;
    /// otherwise nil. An extension that outlasts the stop's end gets none, since the stop ends instead of coming back.
    static func extensionWarningDue(_ snapshot: EngineSnapshot, now: Date) -> Date? {
        guard let active = snapshot.activeHardStop, let until = active.extendedUntil,
              active.endsAt.map({ until < $0 }) ?? true,
              now < until, until.timeIntervalSince(now) <= extensionWarningLead else { return nil }
        return until
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
/// by the overlay with the current time.
struct HardStopConfirmation: Equatable {
    typealias Action = HardStopPresentation.OverlayAction

    static let holdDuration: TimeInterval = 3
    static let confirmWindow: TimeInterval = 5

    enum State: Equatable {
        case idle
        case holding(Action, since: Date)
        case awaitingConfirm(Action, until: Date)
    }

    private(set) var state: State = .idle

    /// The pointer went down on the button for `action`.
    mutating func pressBegan(_ action: Action, at now: Date) {
        state = .holding(action, since: now)
    }

    /// The pointer was released or left the button. Returns the action when the hold lasted long enough and
    /// `update(now:)` has not already returned it.
    mutating func pressEnded(at now: Date) -> Action? {
        guard case .holding(let action, let since) = state else { return nil }
        state = .idle
        return now.timeIntervalSince(since) >= Self.holdDuration ? action : nil
    }

    /// Returns the action whose hold has lasted long enough while still held, once. Also closes an expired confirm window.
    mutating func update(now: Date) -> Action? {
        switch state {
        case .holding(let action, let since) where now.timeIntervalSince(since) >= Self.holdDuration:
            state = .idle
            return action
        case .awaitingConfirm(_, let until) where now >= until:
            state = .idle
        default:
            break
        }
        return nil
    }

    /// The keyboard or VoiceOver activated the button for `action`: the first of two steps.
    mutating func activate(_ action: Action, at now: Date) {
        state = .awaitingConfirm(action, until: now.addingTimeInterval(Self.confirmWindow))
    }

    /// **Confirm** was activated. Returns the action when it came within the confirm window.
    mutating func confirm(at now: Date) -> Action? {
        guard case .awaitingConfirm(let action, let until) = state else { return nil }
        state = .idle
        return now < until ? action : nil
    }

    mutating func cancel() {
        state = .idle
    }

    /// From 0 to 1 while `action` is held, otherwise 0.
    func holdProgress(of action: Action, now: Date) -> Double {
        guard case .holding(action, let since) = state else { return 0 }
        return min(1, max(0, now.timeIntervalSince(since) / Self.holdDuration))
    }

    /// Whole seconds left to confirm, or nil when no confirmation is pending.
    func confirmSecondsLeft(now: Date) -> Int? {
        guard case .awaitingConfirm(_, let until) = state, now < until else { return nil }
        return Int(until.timeIntervalSince(now).rounded(.up))
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
