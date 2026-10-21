import AppKit
import HopCore
import SwiftUI

/// The Settings window. Closing hides it; showing it again brings back the same window. Recording a shortcut ends
/// when the window closes or another window takes focus, so the event tap is never left letting keys through.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        let size = NSSize(width: 520, height: 640)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = "Hop Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.contentMinSize = NSSize(width: 460, height: 360)
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName("HopSettingsWindow")
        window.delegate = self
    }

    func show() {
        model.refreshLoginItem()
        model.refreshScreenRecording()
        // An accessory app is not active until asked; activate so the window comes to the front with focus.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_: Notification) {
        model.stopRecording()
    }

    func windowWillClose(_: Notification) {
        model.stopRecording()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            ShortcutSection(model: model)
            ShownWindowsSection(model: model)
            ExcludedAppsSection(model: model)
            PreviewsSection(model: model)
            LoginSection(model: model)
            PermissionsSection(model: model)
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 360)
    }
}

private struct ShortcutSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            ShortcutRow(model: model, role: .switchWindows, label: "Switch windows")
            ShortcutRow(model: model, role: .sameApp, label: "Switch within the app")
            let shortcut = model.settings.shortcut
            let sameApp = model.settings.sameAppShortcut
            Text("""
                Hold \(shortcut.modifierSymbol) and press \(shortcut.keyName) to switch windows, or hold \
                \(sameApp.modifierSymbol) and press \(sameApp.keyName) to switch among the front app's windows. Add ⇧ to \
                go back, and type to search. Use ⌥ or ⌃ with Tab or `.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Shortcuts")
        }
    }
}

/// One shortcut: what it is, Record Shortcut (or Stop while recording), Reset, and why the last press or reset was
/// refused.
private struct ShortcutRow: View {
    @ObservedObject var model: SettingsModel
    let role: ShortcutRole
    let label: String

    var body: some View {
        let shortcut = model.settings.shortcut(for: role)
        let isRecording = model.recording == role
        LabeledContent(label) {
            HStack {
                Text(isRecording ? "Press a shortcut…" : shortcut.displayName)
                    .monospaced()
                    .foregroundStyle(isRecording ? .secondary : .primary)
                Button(isRecording ? "Stop" : "Record Shortcut") {
                    isRecording ? model.stopRecording() : model.startRecording(role)
                }
                .accessibilityLabel(isRecording ? "Stop recording" : "Record \(label) shortcut")
                Button("Reset to \(role.defaultShortcut.displayName)") { model.resetShortcut(role) }
                    .disabled(shortcut == role.defaultShortcut && !isRecording)
            }
        }
        if model.recorderMessageRole == role, let message = model.recorderMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

private struct ShownWindowsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Toggle("Minimized windows", isOn: option(\.minimized))
            Toggle("Windows of hidden apps", isOn: option(\.hiddenApps))
            Toggle(isOn: option(\.windowlessApps)) {
                Text("Apps with no open windows")
                Text("Shown as the app; choosing it brings the app forward.")
            }
            Toggle("Only windows on the pointer's display", isOn: option(\.pointerDisplayOnly))
        } header: {
            Text("Shown windows")
        }
    }

    private func option(_ keyPath: WritableKeyPath<ShownWindows, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings.shownWindows[keyPath: keyPath] },
            set: { value in model.update { $0.shownWindows[keyPath: keyPath] = value } }
        )
    }
}

private struct ExcludedAppsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            let apps = model.excludedApps
            if apps.isEmpty {
                Text("No apps are excluded.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                HStack {
                    Group {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(app.name ?? app.bundleIdentifier)
                        if app.name != nil {
                            Text(app.bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Remove") { model.include(app.bundleIdentifier) }
                        .accessibilityLabel("Remove \(app.name ?? app.bundleIdentifier)")
                }
            }
            HStack {
                Menu("Add Running App") {
                    let running = model.runningAppsToExclude
                    if running.isEmpty { Text("No other apps are running") }
                    ForEach(running, id: \.bundleIdentifier) { app in
                        Button(app.name) { model.exclude(app.bundleIdentifier) }
                    }
                }
                .fixedSize()
                Button("Add…") { model.chooseAppsToExclude() }
            }
        } header: {
            Text("Excluded apps")
        } footer: {
            Text("Hop never shows windows of excluded apps.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Show window previews: what turning it on means (Screen Recording, asked again from time to time, images in memory
/// only), the link to the Screen Recording pane, and, while previews are on without access, one line saying the
/// switcher shows icons.
private struct PreviewsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.showWindowPreviews },
                set: { model.setShowWindowPreviews($0) }
            )) {
                Text("Show window previews")
                Text("""
                    Shows a recent image of each window instead of its app's icon. macOS asks you to allow Screen \
                    Recording for this, and may ask again from time to time. Images stay in memory and are never saved.
                    """)
            }
            if model.settings.showWindowPreviews {
                if let notice = model.screenRecording.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(notice)
                }
                Button("Open Screen Recording Settings") { model.openScreenRecordingSettings() }
            }
        } header: {
            Text("Window previews")
        }
    }
}

private struct LoginSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Toggle("Open Hop at login", isOn: Binding(
                get: { model.loginItem.isOn },
                set: { model.setLaunchAtLogin($0) }
            ))
            if let note = model.loginItem.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.loginItem.needsApproval {
                Button("Open Login Items") { model.openLoginItems() }
            }
            if let error = model.loginItemError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Launch at login")
        }
    }
}

private struct PermissionsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            LabeledContent("Accessibility") {
                Label(
                    model.isAccessibilityTrusted ? "Allowed" : "Not allowed",
                    systemImage: model.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.isAccessibilityTrusted ? .green : .orange)
            }
            Text("Hop uses Accessibility to list and raise windows and to notice its shortcut.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Privacy & Security") { model.openAccessibilitySettings() }
        } header: {
            Text("Permissions")
        }
    }
}
