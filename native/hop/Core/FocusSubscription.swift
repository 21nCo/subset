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
