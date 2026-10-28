import AppKit
import TimerCore
import UserNotifications

/// A notification the app posts for a `finish` or `missedWhileAway` alert, with the daemon sink's wording
/// (packages/timer-cli/src/alerts/process.mjs `notificationFor`).
struct TimerNotification: Equatable, Sendable {
    static let category = "dev.subset.timer.alert"

    var id: String
    var timerId: String
    var title: String
    var body: String

    /// The notification for `alert`, or nil for the kinds that only play a sound. `name` is the timer's name.
    init?(_ alert: TimerAlert, name: String) {
        switch alert.kind {
        case .finish:
            body = "Finished."
        case .missedWhileAway:
            let count = alert.missed ?? 1
            let now = alert.segment.map { " Now: \($0.label)." } ?? ""
            body = "Missed \(count) alert\(count == 1 ? "" : "s") while away.\(now)"
        case .segment, .tick:
            return nil
        }
        id = alert.alertId ?? "\(alert.timerId)-\(alert.at)-\(alert.kind.rawValue)"
        timerId = alert.timerId
        title = name
    }
}

/// The actions on a Timer notification.
enum NotificationAction: String, CaseIterable, Sendable {
    case restart = "dev.subset.timer.restart"
    case dismiss = "dev.subset.timer.dismiss"

    var title: String {
        switch self {
        case .restart: "Restart"
        case .dismiss: "Dismiss"
        }
    }

    /// The daemon operations the action runs on its timer, in order.
    var operations: [String] {
        switch self {
        case .restart: ["reset", "start"]
        case .dismiss: []
        }
    }

    /// Runs the action's operations on `timerId`, stopping at the first failure. Returns that failure's message.
    @MainActor
    func run(timerId: String, perform: (String, OperationInput) async -> String?) async -> String? {
        for operation in operations {
            if let failure = await perform(operation, OperationInput(id: timerId)) { return failure }
        }
        return nil
    }
}

/// What the app needs from the notification center; tests substitute a fake.
@MainActor
protocol UserNotifying: AnyObject {
    /// Asks for permission if the user has not yet answered, and returns whether notifications are allowed.
    func requestAuthorization() async -> Bool
    /// Whether notifications are allowed now, without asking.
    func isAuthorized() async -> Bool
    /// Returns once the notification center has taken the notification, and throws when it refused it.
    func post(_ notification: TimerNotification) async throws
}

/// The notification center is unavailable, outside an app bundle.
struct NotificationsUnavailable: Error {}

/// `UNUserNotificationCenter`. Outside an app bundle (for example `swift run`) the center is unavailable, so the app
/// reports no permission there and the daemon keeps playing alerts.
@MainActor
final class SystemUserNotifications: NSObject, UserNotifying, UNUserNotificationCenterDelegate {
    /// Runs a notification action's operations.
    var onAction: (NotificationAction, String) -> Void = { _, _ in }

    private lazy var center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    /// Installs the delegate and the actions. Call at launch, so an action that launched the app is not lost.
    func activate() {
        guard let center else { return }
        center.delegate = self
        let actions = NotificationAction.allCases.map { UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: []) }
        center.setNotificationCategories([UNNotificationCategory(identifier: TimerNotification.category, actions: actions, intentIdentifiers: [])])
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        // Asks only while the user has not answered; after that it returns their answer.
        _ = try? await center.requestAuthorization(options: [.alert])
        return await isAuthorized()
    }

    func isAuthorized() async -> Bool {
        guard let center else { return false }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    func post(_ notification: TimerNotification) async throws {
        guard let center else { throw NotificationsUnavailable() }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = TimerNotification.category
        content.userInfo = ["timerId": notification.timerId]
        // The app plays its own sounds; the notification respects Focus as an ordinary one.
        content.sound = nil
        content.interruptionLevel = .active
        try await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = NotificationAction(rawValue: response.actionIdentifier)
        let timerId = response.notification.request.content.userInfo["timerId"] as? String
        if let action, let timerId { Task { @MainActor in self.onAction(action, timerId) } }
        completionHandler()
    }

    /// Shows the banner while the app is active too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// Plays an alert the app has taken over from the daemon, one part at a time (`AlertPart.plan`): a notification naming
/// the timer for `finish` and `missedWhileAway`, and its sounds when the timer's `sound` is on.
@MainActor
struct AlertPresenter {
    let notifications: UserNotifying
    let sounds: SoundPlaying

    /// Presents `part` of `alert` and returns once it has finished; throws when the notification center refused its
    /// notification, so the daemon's sink shows it. Uses the alert's `timerName` and `sound`. An alert without them names
    /// its timer "Timer" and plays its sounds, as the daemon's sink would for a timer it no longer knows.
    func present(_ alert: TimerAlert, _ part: AlertPart) async throws {
        switch part {
        case .notification:
            if let notification = TimerNotification(alert, name: alert.timerName ?? "Timer") { try await notifications.post(notification) }
        case .sound(let index):
            let sequence = SystemSound.sequence(for: alert.kind, soundOn: alert.sound ?? true)
            if sequence.indices.contains(index) { await sounds.play(sequence[index]) }
        }
    }
}
