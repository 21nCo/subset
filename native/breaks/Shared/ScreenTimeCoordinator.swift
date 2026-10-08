import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

@MainActor
final class ScreenTimeCoordinator: ObservableObject {
    @Published private(set) var authorizationStatus: AuthorizationStatus
    @Published var selection: FamilyActivitySelection {
        didSet { saveSelection() }
    }
    @Published var isPickerPresented = false
    @Published private(set) var lastError: String?

    private let authorizationCenter = AuthorizationCenter.shared
    private let store = ManagedSettingsStore(named: .breakReminder)
    private let activityCenter = DeviceActivityCenter()

    init() {
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        selection = Self.loadSelection()
    }

    var isAuthorized: Bool {
        if authorizationStatus == .approved { return true }
        if #available(iOS 26.4, *), authorizationStatus == .approvedWithDataAccess { return true }
        return false
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = authorizationCenter.authorizationStatus
    }

    func requestAuthorization() async {
        do {
            try await authorizationCenter.requestAuthorization(for: .individual)
            authorizationStatus = authorizationCenter.authorizationStatus
            lastError = nil
        } catch {
            authorizationStatus = authorizationCenter.authorizationStatus
            lastError = error.localizedDescription
        }
    }

    func applyShield(settings: BreakSettings) {
        guard settings.screenTimeEnforcement, isAuthorized else { return }

        if settings.shieldEveryAppAndWebsite {
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
        } else {
            store.shield.applications = selection.applicationTokens
            store.shield.applicationCategories = .specific(selection.categoryTokens)
            store.shield.webDomains = selection.webDomainTokens
        }
    }

    func clearShield() {
        store.clearAllSettings()
    }

    func refreshSchedules(settings: BreakSettings) {
        let owned = activityCenter.activities.filter { $0.rawValue.hasPrefix("break.") }
        activityCenter.stopMonitoring(owned)
        guard isAuthorized else { return }

        scheduleFocusWindow(settings: settings)
        for planned in settings.plannedBreaks where planned.isEnabled {
            schedule(planned)
        }
    }

    private func scheduleFocusWindow(settings: BreakSettings) {
        let start = DateComponents(hour: settings.officeHours.startHour, minute: settings.officeHours.startMinute)
        let end = DateComponents(hour: settings.officeHours.endHour, minute: settings.officeHours.endMinute)
        let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true, warningTime: DateComponents(minute: 1))
        let event = DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(second: max(60, Int(settings.workInterval)))
        )
        do {
            try activityCenter.startMonitoring(.focusWindow, during: schedule, events: [.init("focus-threshold"): event])
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func schedule(_ planned: PlannedBreak) {
        let start = DateComponents(hour: planned.hour, minute: planned.minute)
        let endDate = Calendar.current.date(
            byAdding: .second,
            value: Int(planned.duration),
            to: Calendar.current.date(from: start) ?? .now
        )
        let end = DateComponents(
            hour: Calendar.current.component(.hour, from: endDate ?? .now),
            minute: Calendar.current.component(.minute, from: endDate ?? .now)
        )
        let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true, warningTime: DateComponents(minute: 1))
        do {
            try activityCenter.startMonitoring(.init("break.planned.\(planned.id.uuidString)"), during: schedule)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func saveSelection() {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        SharedStore.defaults.set(data, forKey: SharedStore.selectionKey)
    }

    private static func loadSelection() -> FamilyActivitySelection {
        guard
            let data = SharedStore.defaults.data(forKey: SharedStore.selectionKey),
            let value = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return FamilyActivitySelection(includeEntireCategory: true) }
        return value
    }
}
