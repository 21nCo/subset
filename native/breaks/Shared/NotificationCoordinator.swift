import Foundation
import Combine
import UserNotifications

final class NotificationActionRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationActionRouter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let command: String?
        switch response.actionIdentifier {
        case NotificationCoordinator.startAction: command = "start"
        case NotificationCoordinator.snoozeOneAction: command = "snooze:1"
        case NotificationCoordinator.snoozeFiveAction: command = "snooze:5"
        case NotificationCoordinator.snoozeFifteenAction: command = "snooze:15"
        default: command = response.notification.request.content.categoryIdentifier == SharedStore.notificationCategory ? "open" : nil
        }
        if let command {
            BreakRepository().setCommand(command)
        }
        completionHandler()
    }
}

@MainActor
final class NotificationCoordinator: ObservableObject {
    static let breakCategory = SharedStore.notificationCategory
    static let startAction = "START_BREAK"
    static let snoozeOneAction = "SNOOZE_ONE"
    static let snoozeFiveAction = "SNOOZE_FIVE"
    static let snoozeFifteenAction = "SNOOZE_FIFTEEN"

    @Published private(set) var isAuthorized = false
    private let center = UNUserNotificationCenter.current()

    init() {
        center.delegate = NotificationActionRouter.shared
        configureCategories()
        refreshAuthorizationStatus()
    }

    func requestAuthorization() async {
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            isAuthorized = false
        }
    }

    func refreshAuthorizationStatus() {
        Task {
            let settings = await center.notificationSettings()
            isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    func schedule(settings: BreakSettings, snapshot: EngineSnapshot, now: Date = .now) {
        center.removePendingNotificationRequests(withIdentifiers: ["heads-up", "break-due", "posture", "blink"])
        guard snapshot.phase == .focusing || snapshot.phase == .headsUp else { return }

        if settings.reminder.headsUpEnabled {
            add(
                id: "heads-up",
                title: "Almost time",
                body: "Your eyes will appreciate a pause soon.",
                date: snapshot.nextBreakAt.addingTimeInterval(-settings.reminder.headsUpLeadTime),
                category: Self.breakCategory,
                now: now
            )
        }
        add(
            id: "break-due",
            title: "Time to look into the distance",
            body: "Take a short, screen-free pause.",
            date: snapshot.nextBreakAt,
            category: Self.breakCategory,
            now: now
        )

        if settings.wellness.postureEnabled {
            addRepeating(
                id: "posture",
                title: "Posture check",
                body: "Relax your shoulders and let your spine lengthen.",
                interval: settings.wellness.postureInterval
            )
        }
        if settings.wellness.blinkEnabled {
            addRepeating(
                id: "blink",
                title: "Blink slowly",
                body: "A few full blinks help your eyes feel refreshed.",
                interval: settings.wellness.blinkInterval
            )
        }
    }

    func notifyBreakStarted(duration: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Break started"
        content.body = "Step away for \(duration.compactDuration)."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "break-started", content: content, trigger: nil))
    }

    private func configureCategories() {
        let actions = [
            UNNotificationAction(identifier: Self.startAction, title: "Start now", options: [.foreground]),
            UNNotificationAction(identifier: Self.snoozeOneAction, title: "+1m"),
            UNNotificationAction(identifier: Self.snoozeFiveAction, title: "+5m"),
            UNNotificationAction(identifier: Self.snoozeFifteenAction, title: "+15m")
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.breakCategory, actions: actions, intentIdentifiers: [])
        ])
    }

    private func add(id: String, title: String, body: String, date: Date, category: String, now: Date) {
        guard date > now else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSince(now)), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func addRepeating(id: String, title: String, body: String, interval: TimeInterval) {
        guard interval >= 60 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: true)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
