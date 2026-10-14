import AppKit
import SwiftUI

@main
struct BreaksMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appDelegate.controller)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            MacSettingsView()
                .environmentObject(appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = MacBreakController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject private var controller: MacBreakController

    var body: some View {
        // A hard stop's status shows even with the countdown turned off.
        if controller.settings.desktop.showsMenuBarCountdown || controller.hardStop.menuBar != nil {
            Label(controller.menuBarText, systemImage: controller.menuBarSymbol)
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
                .accessibilityLabel("Breaks: \(controller.statusLine)")
        } else {
            Image(systemName: controller.menuBarSymbol)
                .accessibilityLabel("Breaks: \(controller.statusLine)")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var controller: MacBreakController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(controller.statusLine)

        Divider()

        switch controller.phase {
        case .breaking:
            Button("End break") { controller.endBreak() }
                .disabled(!controller.canEndEarly)
            if controller.settings.discipline != .hardcore {
                Button("Skip break") { controller.skipActiveBreak() }
                    .disabled(!controller.canSkipBreak)
            }
        case .paused:
            Button("Resume reminders") { controller.resume() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            if controller.pauseReason != .manual {
                Button("Pause until I resume") { controller.pause() }
            }
        case .focusing, .headsUp:
            Button("Start break now") { controller.startBreak() }
                .keyboardShortcut("b")
            Menu("Snooze next break") {
                Button("1 minute") { controller.snooze(minutes: 1) }
                Button("5 minutes") { controller.snooze(minutes: 5) }
                Button("15 minutes") { controller.snooze(minutes: 15) }
                Divider()
                Text("\(controller.snoozesRemaining) of \(controller.settings.snoozesAllowedPerDay) snoozes left today")
            }
            .disabled(controller.snoozesRemaining == 0)
            if controller.canSkipUpcomingBreak {
                Button("Skip next break") { controller.skipUpcomingBreak() }
            }
            Menu("Pause reminders") {
                Button("For 30 minutes") { controller.pause(for: 30 * 60) }
                Button("For 1 hour") { controller.pause(for: 60 * 60) }
                Button("For 2 hours") { controller.pause(for: 2 * 60 * 60) }
                Button("Until I resume") { controller.pause() }
            }
        }

        Divider()

        let stats = controller.stats
        Text("Today: \(stats.breaksTaken) breaks, \(stats.skippedBreaks) skipped, score \(stats.screenScore)")
        if let (planned, date) = controller.nextPlannedBreak {
            Text("Next planned: \(planned.name) at \(date.formatted(date: .omitted, time: .shortened))")
        }
        if let next = controller.nextHardStop {
            Text(HardStopText.next(next.stop, start: next.start, now: controller.now, calendar: controller.calendar))
        }
        Button("Hard stop at…") { controller.showHardStopQuickAdd() }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Breaks") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Hard stop at…

/// The **Hard stop at…** panel: a time, a length, and an optional name, which add a one-off hard stop.
@MainActor
final class HardStopQuickAddPanelController {
    private unowned let controller: MacBreakController
    private var panel: NSPanel?

    init(controller: MacBreakController) {
        self.controller = controller
    }

    /// Brings the open panel to the front, or opens it with the default time, length, and name.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = HardStopQuickAddView(
            values: HardStopQuickAdd(now: .now, calendar: controller.calendar),
            close: { [weak panel] in panel?.close() }
        )
        let hosting = NSHostingView(rootView: view.environmentObject(controller))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Hard Stop"
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct HardStopQuickAddView: View {
    @EnvironmentObject private var controller: MacBreakController
    @State var values: HardStopQuickAdd
    @State private var errors: [HardStopFieldError] = []
    let close: () -> Void

    var body: some View {
        Form {
            LabeledContent("Time") {
                HStack {
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    if values.startsTomorrow(now: controller.now, calendar: controller.calendar) {
                        Text("Tomorrow").foregroundStyle(.secondary)
                    }
                }
            }
            Stepper(value: $values.lengthMinutes, in: HardStopQuickAdd.lengthRange, step: 5) {
                LabeledContent("Length", value: HardStopText.length(minutes: values.lengthMinutes))
            }
            TextField("Name", text: $values.name, prompt: Text(HardStopQuickAdd.defaultName))
            ForEach(errors, id: \.message) { error in
                Text(error.message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 320)
    }

    private var time: Binding<Date> {
        Binding(
            get: { controller.calendar.date(bySettingHour: values.hour, minute: values.minute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = controller.calendar.dateComponents([.hour, .minute], from: date)
                values.hour = parts.hour ?? 0
                values.minute = parts.minute ?? 0
            }
        )
    }

    /// Adds the stop when it is valid at the moment Add is pressed; the next tick picks it up.
    private func add() {
        let now = Date.now
        var settings = controller.settings
        errors = settings.saveHardStop(values.stop(now: now, calendar: controller.calendar), isNew: true, now: now, calendar: controller.calendar)
        guard errors.isEmpty else { return }
        controller.settings = settings
        close()
    }
}
