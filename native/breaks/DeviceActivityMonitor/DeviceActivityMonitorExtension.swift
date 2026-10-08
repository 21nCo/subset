import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import UserNotifications

final class BreakDeviceActivityMonitor: DeviceActivityMonitor {
    private let store = ManagedSettingsStore(named: .breakReminder)

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
        guard activity.rawValue.hasPrefix("break.planned.") else { return }
        notify(title: "Planned break in one minute", body: "Finish your thought and find a natural stopping point.")
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard
            activity.rawValue.hasPrefix("break.planned."),
            let planned = plannedBreak(for: activity),
            planned.occurs(on: .now)
        else { return }

        applyShield(settings: BreakRepository().loadSettings())
        SharedStore.defaults.set(Date().addingTimeInterval(planned.duration), forKey: SharedStore.activeBreakEndKey)
        BreakRepository().setCommand("planned:\(planned.id.uuidString)")
        notify(title: planned.name, body: "Your planned break is active for \(planned.duration.compactDuration).")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity.rawValue.hasPrefix("break.planned.") else { return }
        store.clearAllSettings()
        SharedStore.defaults.removeObject(forKey: SharedStore.activeBreakEndKey)
        BreakRepository().clearCommand()
        notify(title: "Break complete", body: "Welcome back. Start gently.")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard activity == .focusWindow else { return }
        notify(title: "Time for your eyes to rest", body: "You reached your focused screen-time interval.")
    }

    private func plannedBreak(for activity: DeviceActivityName) -> PlannedBreak? {
        guard let id = UUID(uuidString: activity.rawValue.replacingOccurrences(of: "break.planned.", with: "")) else { return nil }
        return BreakRepository().loadSettings().plannedBreaks.first { $0.id == id }
    }

    private func applyShield(settings: BreakSettings) {
        guard settings.screenTimeEnforcement else { return }
        if settings.shieldEveryAppAndWebsite {
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
            return
        }

        guard
            let data = SharedStore.defaults.data(forKey: SharedStore.selectionKey),
            let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return }
        store.shield.applications = selection.applicationTokens
        store.shield.applicationCategories = .specific(selection.categoryTokens)
        store.shield.webDomains = selection.webDomainTokens
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = SharedStore.notificationCategory
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
