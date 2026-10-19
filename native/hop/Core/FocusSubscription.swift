import Foundation

/// The focus notifications Hop subscribes to for one app, and which of them the app has accepted. A subscription the
/// app did not answer is tried again on the next `register` while the accepted ones are kept, so an app that was busy
/// once is not left half observed.
public struct FocusSubscription: Sendable, Equatable {
    /// What happened when one notification was added.
    public enum Outcome: Sendable {
        /// The app accepted it, or had already.
        case registered
        /// The app does not post it; it is not tried again.
        case unsupported
        /// The app did not answer or could not be asked; it is tried again on the next `register`.
        case unanswered
    }

    /// The notifications to subscribe to, in the order they are tried.
    public let notifications: [String]
    /// The notifications the app accepted, in the order it accepted them.
    public private(set) var registered: [String] = []
    private var unsupported: Set<String> = []

    public init(_ notifications: [String]) {
        self.notifications = notifications
    }

    /// The notifications still to subscribe to.
    public var pending: [String] {
        notifications.filter { !registered.contains($0) && !unsupported.contains($0) }
    }

    public var isComplete: Bool { pending.isEmpty }

    /// Adds each pending notification in order with `add`. Stops at the first the app does not answer, so an app that
    /// does not respond costs one messaging timeout per call rather than one per notification.
    public mutating func register(using add: (String) -> Outcome) {
        for notification in pending {
            switch add(notification) {
            case .registered: registered.append(notification)
            case .unsupported: unsupported.insert(notification)
            case .unanswered: return
            }
        }
    }
}

/// The focus observers of the apps a tracker follows, owned by the thread that delivers their callbacks. That thread
/// sends the apps no subscription request itself, so an app that does not answer never holds up the callbacks or
/// `removeAll()`: `begin(pid:make:)` hands an app's pending subscriptions to a worker, and the worker's result comes
/// back through `finish(_:)`, which keeps it only if the tracker has not stopped and the app has not quit since.
public struct FocusObservers<Observer: AnyObject> {
    /// One round of an app's subscriptions: the worker calls `subscription.register(using:)` and returns it to
    /// `finish(_:)`. An app has at most one round under way.
    public struct Registration {
        public let pid: pid_t
        public let observer: Observer
        public var subscription: FocusSubscription
        fileprivate let session: UInt64
    }

    /// What the owning thread does with a finished round.
    public enum Outcome {
        /// Kept; `firstScheduled` when the observer now has its first notification, so its run loop source must be
        /// scheduled, and the app's focus read once, since it may have changed before the observer could report it.
        case kept(firstScheduled: Bool)
        /// The tracker stopped or the app quit during the round: the observer is no longer kept.
        case discarded(Removed)
    }

    /// An observer that is no longer kept: remove `notifications` from it, and its source if `isScheduled`.
    public struct Removed {
        public let pid: pid_t
        public let observer: Observer
        public let notifications: [String]
        public let isScheduled: Bool
    }

    private struct Entry {
        let observer: Observer
        var subscription: FocusSubscription
        var isRegistering = false
        var isScheduled = false
    }

    public let notifications: [String]
    private var entries: [pid_t: Entry] = [:]
    /// Advanced by `removeAll()`, so a round that began before it is discarded.
    private var session: UInt64 = 0

    public init(_ notifications: [String]) {
        self.notifications = notifications
    }

    /// Starts a round for the app's pending subscriptions, creating its observer with `make` if it has none. Nil when
    /// the observer cannot be created, every subscription was answered, or a round is already under way.
    public mutating func begin(pid: pid_t, make: () -> Observer?) -> Registration? {
        if entries[pid] == nil {
            guard let observer = make() else { return nil }
            entries[pid] = Entry(observer: observer, subscription: FocusSubscription(notifications))
        }
        guard var entry = entries[pid], !entry.isRegistering, !entry.subscription.isComplete else { return nil }
        entry.isRegistering = true
        entries[pid] = entry
        return Registration(pid: pid, observer: entry.observer, subscription: entry.subscription, session: session)
    }

    public mutating func finish(_ round: Registration) -> Outcome {
        guard round.session == session, var entry = entries[round.pid], entry.observer === round.observer else {
            // Its source was never scheduled: it is scheduled only by a round that is kept.
            return .discarded(Removed(
                pid: round.pid, observer: round.observer, notifications: round.subscription.registered, isScheduled: false
            ))
        }
        entry.subscription = round.subscription
        entry.isRegistering = false
        let firstScheduled = !entry.isScheduled && !entry.subscription.registered.isEmpty
        entry.isScheduled = entry.isScheduled || firstScheduled
        entries[round.pid] = entry
        return .kept(firstScheduled: firstScheduled)
    }

    /// Stops observing an app that quit. A round under way for it is discarded when it finishes.
    public mutating func remove(pid: pid_t) -> Removed? {
        entries.removeValue(forKey: pid).map { Self.removed($0, pid: pid) }
    }

    /// Stops observing every app. Every round under way is discarded when it finishes.
    public mutating func removeAll() -> [Removed] {
        session += 1
        defer { entries.removeAll() }
        return entries.map { Self.removed($0.value, pid: $0.key) }
    }

    private static func removed(_ entry: Entry, pid: pid_t) -> Removed {
        Removed(
            pid: pid, observer: entry.observer, notifications: entry.subscription.registered,
            isScheduled: entry.isScheduled
        )
    }
}
