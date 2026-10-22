import AppKit
import PointInTimeCore
import SwiftUI

/// Drift companion settings: on or off, the threshold, quiet hours, and the optional notification fallback.
@MainActor
final class DriftSettingsWindowController {
    private var window: NSWindow?
    private let model: DriftSettingsModel

    init(companion: DriftCompanionController) {
        model = DriftSettingsModel(companion: companion)
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: DriftSettingsView(model: model)))
            window.title = "pointInTime Drift Companion"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// After the notification permission is read.
    func refresh() { model.reload() }
}

@MainActor
final class DriftSettingsModel: ObservableObject {
    @Published private(set) var revision = 0
    let companion: DriftCompanionController
    var settings: DriftSettings { companion.settings }
    private let calendar = Calendar.autoupdatingCurrent

    init(companion: DriftCompanionController) {
        self.companion = companion
    }

    func reload() { revision += 1 }

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<DriftSettings, T>) -> Binding<T> {
        Binding { self.settings[keyPath: keyPath] } set: { self.settings[keyPath: keyPath] = $0; self.reload() }
    }

    /// A minutes-after-midnight setting as a time of day for the picker.
    func time(_ keyPath: ReferenceWritableKeyPath<DriftSettings, Int>) -> Binding<Date> {
        Binding {
            let minute = self.settings[keyPath: keyPath]
            return self.calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        } set: {
            let parts = self.calendar.dateComponents([.hour, .minute], from: $0)
            self.settings[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            self.reload()
        }
    }

    var notificationFallback: Binding<Bool> {
        Binding { self.settings.notificationFallback } set: {
            self.settings.notificationFallback = $0
            // Permission is asked for only here, when the user turns the fallback on.
            if $0 { self.companion.requestNotifications() }
            self.reload()
        }
    }
}

private struct DriftSettingsView: View {
    @ObservedObject var model: DriftSettingsModel

    var body: some View {
        let _ = model.revision
        Form {
            Section {
                Toggle("Offer the drift companion", isOn: model.binding(\.enabled))
                Picker("Confirm a drift after", selection: model.binding(\.threshold)) {
                    ForEach(Array(DriftRule.thresholds), id: \.self) { count in
                        Text("\(count) Drift blocks (\(count * 3) min)").tag(count)
                    }
                }
                .disabled(!model.settings.enabled)
                Text("""
                    A drift is confirmed when that many consecutive classified blocks in your current session are Drift \
                    with no Focus block between them. Neutral, unclassified, and excluded blocks are skipped; a gap in \
                    recording starts a new session. Each drift is offered once.
                    """)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Quiet hours") {
                Toggle("No drift prompts during quiet hours", isOn: model.binding(\.quietHoursEnabled))
                DatePicker("From", selection: model.time(\.quietStartMinute), displayedComponents: .hourAndMinute)
                    .disabled(!model.settings.quietHoursEnabled)
                DatePicker("To", selection: model.time(\.quietEndMinute), displayedComponents: .hourAndMinute)
                    .disabled(!model.settings.quietHoursEnabled)
                Text("Blocks in quiet hours never count toward a drift. A span from a later time to an earlier one runs past midnight.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("When the panel cannot be shown") {
                Toggle("Send a notification instead", isOn: model.notificationFallback)
                if model.settings.notificationFallback, model.companion.notificationsAllowed == false {
                    Text("Notifications for pointInTime are turned off in System Settings > Notifications, so none is sent.")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("Off by default. Turning it on asks macOS for permission to show alerts, without sounds.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("""
                    Return to Focus starts a 25-minute focus window with no prompts. Take a Break pauses tracking and \
                    prompts for 5, 10, or 15 minutes. Not a Drift saves a Focus or Neutral correction for those blocks, \
                    which later classification requests send as examples, like any correction. No action closes tabs or \
                    quits apps, and the companion itself sends nothing anywhere.
                    """)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
