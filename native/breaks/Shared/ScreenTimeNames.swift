import DeviceActivity
import ManagedSettings

extension ManagedSettingsStore.Name {
    static let breakReminder = Self("break-reminder")
}

extension DeviceActivityName {
    static let focusWindow = Self("break.focus-window")
    /// Ends an app-started break in the background, so its shields lift even if the app is suspended.
    /// Not prefixed with "break." so refreshing the recurring schedules leaves it running.
    static let activeBreak = Self("active-break")
}
