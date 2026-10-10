import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            RemindersSettingsTab()
                .tabItem { Label("Reminders", systemImage: "bell") }
            SmartPauseSettingsTab()
                .tabItem { Label("Smart Pause", systemImage: "pause.circle") }
            ScheduleSettingsTab()
                .tabItem { Label("Schedule", systemImage: "calendar") }
            StatsSettingsTab()
                .tabItem { Label("Stats", systemImage: "chart.bar") }
        }
        .frame(width: 560, height: 520)
    }
}

/// A stepper bound to a duration expressed in whole minutes or seconds.
private struct DurationStepper: View {
    let title: String
    @Binding var value: TimeInterval
    let range: ClosedRange<TimeInterval>
    let step: TimeInterval

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            LabeledContent(title, value: value.compactDuration)
        }
        .accessibilityValue(value.spokenDuration)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var controller: MacBreakController

    var body: some View {
        Form {
            Section("Breaks") {
                DurationStepper(title: "Work for", value: $controller.settings.workInterval, range: 5 * 60...120 * 60, step: 5 * 60)
                DurationStepper(title: "Short break", value: $controller.settings.shortBreakDuration, range: 10...10 * 60, step: 10)
                Toggle("Long breaks", isOn: $controller.settings.longBreakEnabled)
                if controller.settings.longBreakEnabled {
                    DurationStepper(title: "Long break", value: $controller.settings.longBreakDuration, range: 60...30 * 60, step: 60)
                    Stepper(value: $controller.settings.longBreakFrequency, in: 2...8) {
                        LabeledContent("Every", value: "\(controller.settings.longBreakFrequency) breaks")
                    }
                }
            }
            Section("Discipline") {
                Picker("Skipping", selection: $controller.settings.discipline) {
                    ForEach(DisciplineLevel.allCases) { level in
                        Text("\(level.title): \(level.caption)").tag(level)
                    }
                }
                Stepper(value: $controller.settings.snoozesAllowedPerDay, in: 0...20) {
                    LabeledContent("Snoozes per day", value: "\(controller.settings.snoozesAllowedPerDay)")
                }
                Toggle("Allow ending a break near its end", isOn: $controller.settings.allowEarlyEnd)
            }
            Section("Break screen") {
                Picker("Background", selection: $controller.settings.desktop.overlayStyle) {
                    ForEach(OverlayStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Sound", selection: $controller.settings.customization.soundName) {
                    ForEach(["Soft chime", "Tibetan bell", "Forest tone", "Quiet pulse", "None"], id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Slider(value: $controller.settings.customization.soundVolume, in: 0...1) { Text("Volume") }
                    Button("Preview") { controller.previewSound() }
                }
            }
            Section("Menu bar and login") {
                Toggle("Show countdown in the menu bar", isOn: $controller.settings.desktop.showsMenuBarCountdown)
                Toggle("Open Breaks at login", isOn: Binding(
                    get: { controller.launchAtLoginStatus == .enabled || controller.launchAtLoginStatus == .requiresApproval },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                if controller.launchAtLoginStatus == .requiresApproval {
                    HStack {
                        Text("Allow Breaks in System Settings > General > Login Items.")
                            .font(.caption)
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = controller.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshLaunchAtLogin() }
    }
}

// MARK: - Reminders

private struct RemindersSettingsTab: View {
    @EnvironmentObject private var controller: MacBreakController

    var body: some View {
        Form {
            Section("Before a break") {
                Toggle("Show a heads-up notice", isOn: $controller.settings.reminder.headsUpEnabled)
                if controller.settings.reminder.headsUpEnabled {
                    DurationStepper(title: "Notice lead time", value: $controller.settings.reminder.headsUpLeadTime, range: 15...5 * 60, step: 15)
                    Picker("Position", selection: $controller.settings.reminder.position) {
                        ForEach(ReminderPosition.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            Section {
                Toggle("Blink reminders", isOn: $controller.settings.wellness.blinkEnabled)
                if controller.settings.wellness.blinkEnabled {
                    DurationStepper(title: "Every", value: $controller.settings.wellness.blinkInterval, range: 2 * 60...60 * 60, step: 60)
                }
                Toggle("Posture reminders", isOn: $controller.settings.wellness.postureEnabled)
                if controller.settings.wellness.postureEnabled {
                    DurationStepper(title: "Every", value: $controller.settings.wellness.postureInterval, range: 5 * 60...120 * 60, step: 5 * 60)
                }
                Toggle("Larger reminders", isOn: $controller.settings.wellness.largePresentation)
            } header: {
                Text("Blink and posture")
            } footer: {
                Text("A short note appears at the top of the screen for a few seconds and does not take focus. Reminders wait while reminders are paused or a break is close.")
            }
            Section("Break messages") {
                ForEach(controller.settings.customization.messages.indices, id: \.self) { index in
                    TextField("Message \(index + 1)", text: $controller.settings.customization.messages[index])
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Smart pause

private struct SmartPauseSettingsTab: View {
    @EnvironmentObject private var controller: MacBreakController

    var body: some View {
        Form {
            Section {
                Toggle("Meetings and calls", isOn: $controller.settings.smartPause.meetingsAndCalls)
                Toggle("Video playback", isOn: $controller.settings.smartPause.mediaPlayback)
                Toggle("Games in front", isOn: $controller.settings.smartPause.games)
                Toggle("Chosen apps in front", isOn: $controller.settings.smartPause.deepFocusApps)
                DurationStepper(title: "Resume after the signal ends", value: $controller.settings.smartPause.gracePeriod, range: 0...10 * 60, step: 30)
            } header: {
                Text("Pause reminders during")
            } footer: {
                Text("Meetings: another app is using the microphone or a camera. Video: an app is keeping the display awake, which video players, browsers playing video, and keep-awake utilities do. Games: the app in front declares the Games category. Breaks never records audio or video.")
            }

            Section("Apps that pause reminders") {
                if controller.settings.desktop.pauseApps.isEmpty {
                    Text("No apps chosen.").foregroundStyle(.secondary)
                }
                ForEach(controller.settings.desktop.pauseApps) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        Button {
                            controller.settings.desktop.pauseApps.removeAll { $0.id == app.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(app.name)")
                    }
                }
                Button("Add App…", action: chooseApp)
            }

            Section {
                Toggle("Pause when I'm away", isOn: $controller.settings.desktop.idle.isEnabled)
                if controller.settings.desktop.idle.isEnabled {
                    DurationStepper(title: "Pause after", value: $controller.settings.desktop.idle.pauseAfter, range: 30...10 * 60, step: 30)
                    DurationStepper(title: "Start fresh after", value: $controller.settings.desktop.idle.resetAfter, range: 60...60 * 60, step: 60)
                }
            } header: {
                Text("Idle")
            } footer: {
                Text("Away means no keyboard, mouse, or trackpad input. A long absence counts as rest, so the next interval starts from the beginning.")
            }

            Section("Detected now") {
                LabeledContent("Idle", value: controller.lastReading.idleSeconds.compactDuration)
                LabeledContent("Signals", value: detectedSignals)
                LabeledContent("App in front", value: controller.lastReading.frontmostAppName ?? "None")
            }
        }
        .formStyle(.grouped)
    }

    private var detectedSignals: String {
        let names = PauseReason.allCases.filter { controller.lastReading.signals.contains($0) }.map(\.title)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !controller.settings.desktop.pauseApps.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            controller.settings.desktop.pauseApps.append(PauseApp(bundleID: id, name: name))
        }
    }
}

// MARK: - Schedule

private struct ScheduleSettingsTab: View {
    @EnvironmentObject private var controller: MacBreakController

    var body: some View {
        Form {
            Section {
                Toggle("Only remind during office hours", isOn: $controller.settings.officeHours.isEnabled)
                if controller.settings.officeHours.isEnabled {
                    DatePicker("Start", selection: timeBinding(hour: \.officeHours.startHour, minute: \.officeHours.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: timeBinding(hour: \.officeHours.endHour, minute: \.officeHours.endMinute), displayedComponents: .hourAndMinute)
                    WeekdayPicker(selection: $controller.settings.officeHours.weekdays)
                }
            } header: {
                Text("Office hours")
            }

            Section("Planned breaks") {
                ForEach($controller.settings.plannedBreaks) { $planned in
                    VStack(alignment: .leading) {
                        HStack {
                            Toggle(isOn: $planned.isEnabled) { TextField("Name", text: $planned.name) }
                            Button {
                                controller.settings.plannedBreaks.removeAll { $0.id == planned.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(planned.name)")
                        }
                        DatePicker("At", selection: plannedTime($planned), displayedComponents: .hourAndMinute)
                        DurationStepper(title: "For", value: $planned.duration, range: 60...60 * 60, step: 60)
                        WeekdayPicker(selection: $planned.weekdays)
                    }
                }
                Button("Add Planned Break") {
                    var planned = PlannedBreak.sample
                    planned.id = UUID()
                    planned.name = "Planned break"
                    controller.settings.plannedBreaks.append(planned)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func timeBinding(hour: WritableKeyPath<BreakSettings, Int>, minute: WritableKeyPath<BreakSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: controller.settings[keyPath: hour], minute: controller.settings[keyPath: minute], second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                controller.settings[keyPath: hour] = parts.hour ?? 0
                controller.settings[keyPath: minute] = parts.minute ?? 0
            }
        )
    }

    private func plannedTime(_ planned: Binding<PlannedBreak>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: planned.wrappedValue.hour, minute: planned.wrappedValue.minute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                planned.wrappedValue.hour = parts.hour ?? 0
                planned.wrappedValue.minute = parts.minute ?? 0
            }
        )
    }
}

private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private let symbols = Calendar.current.veryShortWeekdaySymbols
    private let names = Calendar.current.weekdaySymbols

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                Toggle(symbols[day - 1], isOn: Binding(
                    get: { selection.contains(day) },
                    // At least one day stays selected; an empty schedule would never run.
                    set: { isOn in
                        if isOn {
                            selection.insert(day)
                        } else if selection.count > 1 {
                            selection.remove(day)
                        }
                    }
                ))
                .toggleStyle(.button)
                .accessibilityLabel(names[day - 1])
            }
        }
    }
}

// MARK: - Stats

private struct StatsSettingsTab: View {
    @EnvironmentObject private var controller: MacBreakController

    var body: some View {
        let stats = controller.stats
        Form {
            Section("Today") {
                LabeledContent("Screen Score", value: "\(stats.screenScore)")
                LabeledContent("Breaks taken", value: "\(stats.breaksTaken)")
                LabeledContent("Break time", value: stats.breakTime.compactDuration)
                LabeledContent("Skipped", value: "\(stats.skippedBreaks)")
                LabeledContent("Snoozes", value: "\(stats.snoozes)")
                LabeledContent("Focus time", value: stats.focusTime.compactDuration)
                LabeledContent("Longest stretch", value: stats.longestStretch.compactDuration)
            }
            Section("Recent breaks") {
                let recent = controller.records.suffix(15).reversed()
                if recent.isEmpty {
                    Text("No breaks yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(recent)) { record in
                    LabeledContent(record.kind.title) {
                        Text("\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.skipped ? "Skipped" : record.actualDuration.compactDuration)")
                    }
                }
            }
            Section {
                Button("Reset Today", role: .destructive) { controller.resetToday() }
            } footer: {
                Text("History stays on this Mac. Breaks has no account, network access, or analytics.")
            }
        }
        .formStyle(.grouped)
    }
}
