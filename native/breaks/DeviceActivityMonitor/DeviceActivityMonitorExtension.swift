import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import UserNotifications

final class BreakDeviceActivityMonitor: DeviceActivityMonitor {
    private let store = ManagedSettingsStore(named: .breakReminder)

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
        // The schedule repeats daily; only warn on the planned break's own weekdays.
        guard activity.rawValue.hasPrefix("break.planned."), let planned = plannedBreak(for: activity), planned.occurs(on: .now) else { return }
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
        if activity == .activeBreak {
            // An app-started break ended while the app may be suspended.
            liftShieldsIfNoLaterBreak()
            return
        }
        // The schedule repeats daily; on other weekdays no planned break started, so there is nothing to end.
        guard activity.rawValue.hasPrefix("break.planned."), let planned = plannedBreak(for: activity), planned.occurs(on: .now) else { return }
        BreakRepository().clearCommand(ifEqualTo: "planned:\(planned.id.uuidString)")
        guard liftShieldsIfNoLaterBreak() else { return }
        notify(title: "Break complete", body: "Welcome back. Start gently.")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard activity == .focusWindow, BreakRepository().loadSettings().officeHours.contains(.now) else { return }
        notify(title: "Time for your eyes to rest", body: "You reached your focused screen-time interval.", actionable: true)
    }

    /// Clears the shields unless another break, one that ends later, is still running. Returns whether it did.
    @discardableResult
    private func liftShieldsIfNoLaterBreak() -> Bool {
        if let end = SharedStore.defaults.object(forKey: SharedStore.activeBreakEndKey) as? Date,
           end > Date().addingTimeInterval(60) {
            return false
        }
        store.clearAllSettings()
        SharedStore.defaults.removeObject(forKey: SharedStore.activeBreakEndKey)
        return true
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

    /// Only `actionable` notifications get the Start and Snooze actions; the others are informational.
    private func notify(title: String, body: String, actionable: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if actionable { content.categoryIdentifier = SharedStore.notificationCategory }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
