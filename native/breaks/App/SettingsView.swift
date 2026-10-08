import FamilyControls
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var engine: BreakEngine

    var body: some View {
        List {
            Section("Focus & Wellbeing") {
                NavigationLink { ScreenBreakSettingsView() } label: {
                    SettingsRow(icon: "eyes", color: BreakPalette.magenta, title: "Screen Breaks", subtitle: "Intervals, duration, enforcement")
                }
                NavigationLink { SmartPauseSettingsView() } label: {
                    SettingsRow(icon: "pause.fill", color: BreakPalette.violet, title: "Smart Pause", subtitle: "Focus modes and high engagement")
                }
                NavigationLink { WellnessSettingsView() } label: {
                    SettingsRow(icon: "heart.fill", color: BreakPalette.coral, title: "Wellness Reminders", subtitle: "Posture and blink nudges")
                }
            }
            Section("Behavior & Feedback") {
                NavigationLink { AlertsSettingsView() } label: {
                    SettingsRow(icon: "rectangle.topthird.inset.filled", color: BreakPalette.magenta, title: "Alerts / Nudges", subtitle: "Heads-up, countdown, overtime")
                }
                NavigationLink { AppearanceSettingsView() } label: {
                    SettingsRow(icon: "speaker.wave.2.fill", color: BreakPalette.coral, title: "Sounds & Appearance", subtitle: "Ambience, sound, messages")
                }
            }
            Section("Integrations") {
                NavigationLink { ScreenTimeSettingsView() } label: {
                    SettingsRow(icon: "hourglass.badge.plus", color: BreakPalette.violet, title: "Screen Time", subtitle: engine.screenTime.isAuthorized ? "Authorized" : "Setup required")
                }
                NavigationLink { AutomationSettingsView() } label: {
                    SettingsRow(icon: "arrow.triangle.2.circlepath", color: BreakPalette.amber, title: "Automation", subtitle: "Shortcuts and Focus Filters")
                }
            }
            Section {
                NavigationLink { AboutView() } label: {
                    SettingsRow(icon: "info.circle.fill", color: BreakPalette.teal, title: "About", subtitle: "System support and privacy")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { AmbientBackground(style: .classic) }
        .navigationTitle("Settings")
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsGlyph(icon: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct SmartPauseSettingsView: View {
    @EnvironmentObject private var engine: BreakEngine

    var body: some View {
        Form {
            Section {
                Toggle("Focus Mode", isOn: $engine.settings.smartPause.focusMode)
                Toggle("Meetings or calls", isOn: $engine.settings.smartPause.meetingsAndCalls)
                Toggle("Video or audio playback", isOn: $engine.settings.smartPause.mediaPlayback)
                Toggle("Calendar events", isOn: $engine.settings.smartPause.calendarEvents)
                Toggle("Deep focus apps", isOn: $engine.settings.smartPause.deepFocusApps)
                Toggle("Fullscreen games", isOn: $engine.settings.smartPause.games)
            } header: {
                Text("High engagement activities")
            } footer: {
                Text("iOS does not expose arbitrary app state to third-party apps. Focus Filters pause automatically; the other choices shape notifications and Screen Time behavior where the system provides a signal.")
            }
            Section("After an activity") {
                Stepper(value: $engine.settings.smartPause.gracePeriod, in: 0...600, step: 30) {
                    LabeledContent("Grace period", value: engine.settings.smartPause.gracePeriod.compactDuration)
                }
            }
        }
        .navigationTitle("Smart Pause")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WellnessSettingsView: View {
    @EnvironmentObject private var engine: BreakEngine

    var body: some View {
        Form {
            Section("Posture reminders") {
                Toggle("Enabled", isOn: $engine.settings.wellness.postureEnabled)
                if engine.settings.wellness.postureEnabled {
                    Stepper(value: $engine.settings.wellness.postureInterval, in: 5 * 60...120 * 60, step: 5 * 60) {
                        LabeledContent("Remind every", value: engine.settings.wellness.postureInterval.compactDuration)
                    }
                }
            }
            Section("Blink reminders") {
                Toggle("Enabled", isOn: $engine.settings.wellness.blinkEnabled)
                if engine.settings.wellness.blinkEnabled {
                    Stepper(value: $engine.settings.wellness.blinkInterval, in: 2 * 60...60 * 60, step: 60) {
                        LabeledContent("Remind every", value: engine.settings.wellness.blinkInterval.compactDuration)
                    }
                }
            }
            Section("Presentation") {
                Toggle("Dim the background", isOn: $engine.settings.wellness.dimsBackground)
                Toggle("Use large reminders", isOn: $engine.settings.wellness.largePresentation)
            }
        }
        .navigationTitle("Wellness Reminders")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AlertsSettingsView: View {
    @EnvironmentObject private var engine: BreakEngine

    var body: some View {
        Form {
            Section("Positioning") {
                HStack(spacing: 8) {
                    ForEach(ReminderPosition.allCases) { position in
                        Button { engine.settings.reminder.position = position } label: {
                            ReminderPositionPreview(position: position, selected: engine.settings.reminder.position == position)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Break reminder") {
                Toggle("Show a reminder before a break appears", isOn: $engine.settings.reminder.headsUpEnabled)
                if engine.settings.reminder.headsUpEnabled {
                    Stepper(value: $engine.settings.reminder.headsUpLeadTime, in: 10...600, step: 10) {
                        LabeledContent("Show reminder", value: "\(engine.settings.reminder.headsUpLeadTime.compactDuration) before")
                    }
                    Stepper(value: $engine.settings.reminder.visibleDuration, in: 5...60, step: 5) {
                        LabeledContent("Keep visible for", value: engine.settings.reminder.visibleDuration.compactDuration)
                    }
                }
            }
            Section("Countdown before break") {
                Toggle("Enabled", isOn: $engine.settings.reminder.countdownEnabled)
                Stepper(value: $engine.settings.reminder.countdownDuration, in: 3...15, step: 1) {
                    LabeledContent("Countdown duration", value: engine.settings.reminder.countdownDuration.compactDuration)
                }
            }
            Section("Overtime nudge") {
                Toggle("Enabled", isOn: $engine.settings.reminder.overtimeNudgeEnabled)
                Toggle("Show even when paused", isOn: $engine.settings.reminder.overtimeShowsWhenPaused)
            }
        }
        .navigationTitle("Alerts / Nudges")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReminderPositionPreview: View {
    let position: ReminderPosition
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: alignment) {
                RoundedRectangle(cornerRadius: 10).fill(BreakPalette.accentGradient.opacity(0.55)).frame(height: 62)
                RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.72)).frame(width: 32, height: 12).padding(5)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? BreakPalette.magenta : .clear, lineWidth: 2))
            Text(position.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var alignment: Alignment {
        switch position {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        }
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var engine: BreakEngine
    @State private var newMessage = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isImportingSound = false
    @State private var importError: String?

    var body: some View {
        Form {
            Section("Break background") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(BreakBackground.allCases) { background in
                        Button { engine.settings.customization.background = background } label: {
                            ZStack(alignment: .bottomLeading) {
                                BackgroundSwatch(background: background)
                                Text(background.title).font(.caption.weight(.semibold)).padding(9)
                            }
                            .frame(height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(engine.settings.customization.background == background ? .white : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose a custom image", systemImage: "photo.badge.plus")
                }
                .onChange(of: photoItem) { _, item in
                    guard let item else { return }
                    Task {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else { return }
                            try AppGroupAssets.save(data, filename: "custom-break-background")
                            engine.settings.customization.customBackgroundFilename = "custom-break-background"
                            engine.settings.customization.background = .custom
                        } catch {
                            importError = error.localizedDescription
                        }
                    }
                }
            }
            Section("Sounds") {
                Picker("Break sound", selection: $engine.settings.customization.soundName) {
                    ForEach(["Soft chime", "Tibetan bell", "Forest tone", "Quiet pulse", "None"], id: \.self) { Text($0).tag($0) }
                    if engine.settings.customization.customSoundFilename != nil {
                        Text("Custom audio").tag("Custom audio")
                    }
                }
                Slider(value: $engine.settings.customization.soundVolume, in: 0...1) {
                    Text("Volume")
                } minimumValueLabel: { Image(systemName: "speaker.fill") } maximumValueLabel: { Image(systemName: "speaker.wave.3.fill") }
                Toggle("Haptics", isOn: $engine.settings.customization.hapticsEnabled)
                Button("Preview sound") { engine.previewSound() }
                    .disabled(engine.settings.customization.soundName == "None")
                Button { isImportingSound = true } label: {
                    Label("Import a sound", systemImage: "waveform.badge.plus")
                }
            }
            Section("Custom messages") {
                ForEach(Array(engine.settings.customization.messages.enumerated()), id: \.offset) { index, message in
                    HStack {
                        Text(message)
                        Spacer()
                        Button(role: .destructive) { engine.settings.customization.messages.remove(at: index) } label: { Image(systemName: "trash") }
                    }
                }
                HStack {
                    TextField("Add a gentle message", text: $newMessage)
                    Button("Add") {
                        let value = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        engine.settings.customization.messages.append(value)
                        newMessage = ""
                    }
                    .disabled(newMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .fileImporter(isPresented: $isImportingSound, allowedContentTypes: [.audio]) { result in
            do {
                let source = try result.get()
                let hasAccess = source.startAccessingSecurityScopedResource()
                defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: source)
                let fileExtension = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
                let filename = "custom-break-sound.\(fileExtension)"
                try AppGroupAssets.save(data, filename: filename)
                engine.settings.customization.customSoundFilename = filename
                engine.settings.customization.soundName = "Custom audio"
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert("Couldn't import that asset", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown error")
        }
        .navigationTitle("Sounds & Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BackgroundSwatch: View {
    let background: BreakBackground
    var body: some View {
        Group {
            switch background {
            case .ambient:
                Image("AmbientBreak").resizable().scaledToFill()
            case .aurora:
                LinearGradient(colors: [BreakPalette.teal, .blue, BreakPalette.violet], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .dusk:
                LinearGradient(colors: [BreakPalette.amber, BreakPalette.coral, BreakPalette.magenta], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .classic:
                LinearGradient(colors: [.gray.opacity(0.6), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .custom:
                if let filename = BreakRepository().loadSettings().customization.customBackgroundFilename,
                   let url = AppGroupAssets.url(for: filename),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [BreakPalette.ink, BreakPalette.magenta.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
    }
}

struct ScreenTimeSettingsView: View {
    @EnvironmentObject private var engine: BreakEngine

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    SettingsGlyph(icon: engine.screenTime.isAuthorized ? "checkmark.shield.fill" : "lock.shield.fill", color: engine.screenTime.isAuthorized ? BreakPalette.teal : BreakPalette.violet)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.screenTime.isAuthorized ? "Screen Time is ready" : "Authorization required").font(.headline)
                        Text(engine.screenTime.isAuthorized ? "Break shielding can continue outside the app." : "Allow individual authorization to enforce breaks.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !engine.screenTime.isAuthorized {
                    Button("Authorize Screen Time") { Task { await engine.screenTime.requestAuthorization() } }
                }
            }
            Section("Enforcement") {
                Toggle("Shield apps and websites during breaks", isOn: $engine.settings.screenTimeEnforcement)
                Toggle("Shield every non-essential app and website", isOn: $engine.settings.shieldEveryAppAndWebsite)
                if !engine.settings.shieldEveryAppAndWebsite {
                    Button("Choose apps, categories, and websites") { engine.screenTime.isPickerPresented = true }
                    LabeledContent("Selected") {
                        Text("\(engine.screenTime.selection.applicationTokens.count) apps · \(engine.screenTime.selection.categoryTokens.count) categories")
                    }
                }
            }
            Section {
                Button("Clear active shields", role: .destructive) { engine.screenTime.clearShield() }
            } footer: {
                Text("System apps required for safety and communication may remain available. Production distribution requires the Family Controls entitlement on the app and each Screen Time extension.")
            }
            if let error = engine.screenTime.lastError {
                Section("Last system message") { Text(error).foregroundStyle(.secondary) }
            }
        }
        .familyActivityPicker(
            headerText: "Selected apps and sites are shielded whenever a break is active.",
            footerText: "You can change this selection at any time.",
            isPresented: Binding(
                get: { engine.screenTime.isPickerPresented },
                set: { engine.screenTime.isPickerPresented = $0 }
            ),
            selection: Binding(
                get: { engine.screenTime.selection },
                set: { engine.screenTime.selection = $0 }
            )
        )
        .navigationTitle("Screen Time")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AutomationSettingsView: View {
    @EnvironmentObject private var engine: BreakEngine
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Break start") {
                Toggle("Run a Shortcut", isOn: $engine.settings.automation.runStartShortcut)
                if engine.settings.automation.runStartShortcut {
                    TextField("Shortcut name", text: $engine.settings.automation.startShortcutName)
                }
            }
            Section("Break end") {
                Toggle("Run a Shortcut", isOn: $engine.settings.automation.runEndShortcut)
                if engine.settings.automation.runEndShortcut {
                    TextField("Shortcut name", text: $engine.settings.automation.endShortcutName)
                }
            }
            Section("Built-in actions") {
                Label("Start a Mindful Break", systemImage: "eyes")
                Label("Pause Break Reminders", systemImage: "pause.fill")
                Label("Resume Break Reminders", systemImage: "play.fill")
                Label("Breaks Focus Filter", systemImage: "moon.stars.fill")
                Button("Open Shortcuts") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
            }
        }
        .navigationTitle("Automation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    @EnvironmentObject private var engine: BreakEngine
    @AppStorage("onboarding.completed", store: SharedStore.defaults) private var onboardingCompleted = true

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    RestMark(size: 88)
                    Text("Breaks").font(.title2.bold())
                    Text("A calm, privacy-first break companion for iPhone and iPad.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            Section("System support") {
                LabeledContent("Notifications", value: engine.notifications.isAuthorized ? "Ready" : "Not authorized")
                LabeledContent("Screen Time", value: engine.screenTime.isAuthorized ? "Ready" : "Not authorized")
                LabeledContent("Live Activities", value: "Supported")
                LabeledContent("Device family", value: "iPhone & iPad")
            }
            Section("Privacy") {
                Text("Settings, selections, and break history remain on device. Breaks includes no analytics SDK, advertising SDK, account, or remote data collection.")
            }
            Section {
                Button("Show onboarding again") { onboardingCompleted = false }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
