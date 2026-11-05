import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var preferences: AppPreferences
    /// Bumped by "Check Again" so permission rows re-read the live system state.
    @State private var permissionRefresh = 0
    @StateObject private var shortcutRecorder = ShortcutRecorder()

    init(appState: AppState) {
        self.appState = appState
        preferences = appState.preferences
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $preferences.selectedSettingsTab) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(preferences.selectedSettingsTab.title, systemImage: preferences.selectedSettingsTab.symbol)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    settingsContent
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: preferences.selectedSettingsTab) { _, _ in shortcutRecorder.stop() }
        .onDisappear { shortcutRecorder.stop() }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch preferences.selectedSettingsTab {
        case .general: general
        case .wallpaper: wallpaper
        case .shortcuts: shortcuts
        case .quickAccess: quickAccess
        case .recording: recording
        case .screenshots: screenshots
        case .annotate: annotate
        case .cloud: cloud
        case .advanced: advanced
        case .about: about
        }
    }

    private var general: some View {
        VStack(spacing: 14) {
            if !screenRecordingGranted {
                settingsGroup("Get started") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Screenshot needs Screen Recording permission before it can capture or record. macOS asks the first time you capture; you can also grant it now in System Settings, then quit and reopen Screenshot.")
                            .fixedSize(horizontal: false, vertical: true)
                        permissionRow("Screen Recording", granted: screenRecordingGranted, pane: "Privacy_ScreenCapture")
                        permissionRow("Accessibility (scrolling capture and keystrokes only)", granted: accessibilityGranted, pane: "Privacy_Accessibility")
                        Text(captureAreaHint)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            settingsGroup("After capture") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AfterCaptureAction.allCases) { action in
                        Toggle(action.title, isOn: actionBinding(action))
                    }
                    Text("Actions run together. Quick Access stays available for any follow-up action.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            settingsGroup("History") {
                HStack {
                    Text("Keep captures for")
                    Spacer()
                    Picker("Keep captures for", selection: $preferences.historyDays) {
                        Text("1 day").tag(1)
                        Text("1 week").tag(7)
                        Text("1 month").tag(30)
                        Text("Forever").tag(36_500)
                    }.labelsHidden().frame(width: 150)
                }
            }
        }
    }

    private var wallpaper: some View {
        settingsGroup("Desktop capture") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Window captures can be placed on a wallpaper in the Annotate Background tool.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach([Color.purple, .blue, .pink, .orange], id: \.self) { color in
                        RoundedRectangle(cornerRadius: 10).fill(color.gradient).frame(width: 74, height: 48)
                    }
                }
            }
        }
    }

    private var shortcuts: some View {
        VStack(spacing: 14) {
            settingsGroup("Global shortcuts") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(GlobalShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                        if index > 0 { Divider() }
                        globalShortcutRow(action)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("These shortcuts work from any app. Click a shortcut and press the new keys; press Esc to cancel. A shortcut needs ⌃, or ⌘ with ⌥ or ⇧.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Reset All") {
                            shortcutRecorder.stop()
                            shortcutRecorder.clearMessage()
                            preferences.globalShortcuts.resetAll()
                            appState.registerGlobalShortcuts()
                        }
                        .disabled(preferences.globalShortcuts.isAllDefault)
                    }
                    .padding(.top, 8)
                }
            }
            settingsGroup("Annotate editor") {
                VStack(spacing: 0) {
                    shortcutRow("Undo / Redo", "⌘Z / ⇧⌘Z")
                    Divider()
                    shortcutRow("Save editable project", "⌘S")
                    Divider()
                    shortcutRow("Copy annotated image", "⇧⌘C")
                    Divider()
                    shortcutRow("Export", "⌘E")
                    Divider()
                    shortcutRow("Delete selected annotation", "⌘⌫")
                }
            }
            settingsGroup("Automation URLs") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["capture-area", "capture-window", "capture-fullscreen", "scrolling-capture", "record-screen", "capture-text", "history"], id: \.self) { action in
                        Text("subset-screenshot://\(action)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func globalShortcutRow(_ action: GlobalShortcutAction) -> some View {
        let shortcut = preferences.globalShortcuts.shortcut(for: action)
        let isRecording = shortcutRecorder.action == action
        let pending = KeyShortcut.symbols(for: shortcutRecorder.pendingModifiers)
        let label = isRecording ? (pending.isEmpty ? "Type shortcut…" : pending + "…") : (shortcut?.displayString ?? "None")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(action.title)
                Spacer()
                Button {
                    if isRecording {
                        shortcutRecorder.stop()
                        shortcutRecorder.clearMessage()
                    } else {
                        shortcutRecorder.start(action, appState: appState)
                    }
                } label: {
                    Text(label)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(shortcut == nil && !isRecording ? .secondary : .primary)
                        .frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                .help(isRecording ? "Press the new shortcut, or Esc to cancel" : "Click to record a new shortcut")
                .accessibilityLabel("\(action.title) shortcut")
                .accessibilityValue(isRecording ? "Recording" : (shortcut?.displayString ?? "None"))
                .accessibilityHint(isRecording ? "Press the new shortcut, or Escape to cancel" : "Records a new shortcut")
                Button {
                    shortcutRecorder.stop()
                    // Clearing can resolve a conflict reported on another row.
                    shortcutRecorder.clearMessage()
                    preferences.globalShortcuts.clear(action)
                    appState.registerGlobalShortcuts()
                } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .disabled(shortcut == nil)
                .help("Remove this shortcut")
                .accessibilityLabel("Remove \(action.title) shortcut")
                Button {
                    shortcutRecorder.stop()
                    if let conflict = preferences.globalShortcuts.reset(action) {
                        shortcutRecorder.show("\(action.defaultShortcut.displayString) is already used by \(conflict.title). Change that shortcut first.", for: action)
                    } else {
                        shortcutRecorder.clearMessage()
                        appState.registerGlobalShortcuts()
                    }
                } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .disabled(preferences.globalShortcuts.isDefault(action))
                .help("Reset to \(action.defaultShortcut.displayString)")
                .accessibilityLabel("Reset \(action.title) shortcut to \(action.defaultShortcut.displayString)")
            }
            if let message = shortcutRecorder.message, message.action == action {
                Text(message.text).font(.caption).foregroundStyle(.orange)
            } else if appState.unavailableShortcuts.contains(action) {
                Text("macOS did not accept this shortcut; another app may already use it. Choose another one.")
                    .font(.caption).foregroundStyle(.orange)
            } else if shortcut?.overlapsSystemScreenshotShortcut == true {
                Text("macOS's own screenshot shortcut takes priority. Turn it off in System Settings > Keyboard > Keyboard Shortcuts > Screenshots.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
    }

    private var quickAccess: some View {
        VStack(spacing: 14) {
            settingsGroup("Overlay size") {
                HStack {
                    Text("Small")
                    Slider(value: $preferences.quickAccessSize, in: 1...3, step: 1)
                    Text("Large")
                }
            }
            settingsGroup("Overlay behavior") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Close automatically")
                        Spacer()
                        Picker("Close automatically", selection: $preferences.quickAccessAutoCloseSeconds) {
                            Text("Never").tag(0)
                            Text("After 5 seconds").tag(5)
                            Text("After 10 seconds").tag(10)
                            Text("After 30 seconds").tag(30)
                        }.labelsHidden().frame(width: 170)
                    }
                    Text("A bar on the overlay shows the time left. Hovering over the overlay pauses the countdown; moving away starts it again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The overlay supports drag-and-drop, context actions, upload progress, pinning, and reopening editable annotations.")
                        .foregroundStyle(.secondary)
                    Button("Restore Last Capture") { appState.restoreMostRecent() }
                }
            }
        }
    }

    private var recording: some View {
        VStack(spacing: 14) {
            settingsGroup("Audio and presentation") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Record computer audio", isOn: $preferences.recordSystemAudio)
                    Toggle("Record microphone", isOn: $preferences.recordMicrophone)
                    Toggle("Show camera overlay", isOn: $preferences.showCamera)
                    Toggle("Show keystrokes", isOn: $preferences.showKeystrokes)
                    Toggle("Highlight mouse clicks", isOn: $preferences.highlightClicks)
                }
            }
            settingsGroup("Recording controls") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show controls while recording", isOn: $preferences.showRecordingControls)
                    Toggle("Display recording time", isOn: $preferences.showRecordingTime)
                    Toggle("Open Video Editor after recording", isOn: $preferences.openVideoEditor)
                }
            }
        }
    }

    private var screenshots: some View {
        VStack(spacing: 14) {
            settingsGroup("Capture") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Capture cursor", isOn: $preferences.includeCursor)
                    Toggle("Capture window shadow", isOn: $preferences.captureWindowShadow)
                }
            }
            settingsGroup("Saving") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Format")
                        Spacer()
                        Picker("Format", selection: $preferences.imageFormat) {
                            Text("PNG").tag("png")
                            Text("JPEG").tag("jpeg")
                        }.labelsHidden().frame(width: 120)
                    }
                    HStack {
                        Text("File name")
                        TextField("Screenshot {date} at {time}", text: $preferences.fileNamePattern)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Export location")
                        Spacer()
                        Text(preferences.exportDirectory.path).lineLimit(1).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseExportDirectory)
                    }
                }
            }
        }
    }

    private var annotate: some View {
        settingsGroup("Editor defaults") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The editor remembers the last tool, color, stroke width, text size, pixelation mode, snapping preference, and background preset.")
                    .foregroundStyle(.secondary)
                Button("Open Last Capture in Annotate") {
                    if let record = appState.history.records.first { appState.openEditor(record: record) }
                }
            }
        }
    }

    private var cloud: some View {
        VStack(spacing: 14) {
            settingsGroup("Hosted sharing") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        preferences.isCloudConfigured ? "Ready to upload" : "Not set up",
                        systemImage: preferences.isCloudConfigured ? "checkmark.circle.fill" : "icloud.slash"
                    )
                    .foregroundStyle(preferences.isCloudConfigured ? .green : .secondary)
                    Text("Sharing is optional and off by default. Subset does not run a share service; deploy the share Worker from this app's source to your own Cloudflare account, then enter its URL and upload token. Captures stay on this Mac until you choose Upload.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Share Worker URL (https://…)", text: $preferences.cloudBaseURL)
                        .textFieldStyle(.roundedBorder)
                    if !preferences.cloudBaseURL.isEmpty, CloudShareService.validatedBaseURL(preferences.cloudBaseURL) == nil {
                        Text("Use an https URL (plain http is accepted only for localhost).")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    SecureField("Upload token (stored in the Keychain)", text: $preferences.uploadToken)
                        .textFieldStyle(.roundedBorder)
                    Text("Uploads produce a shareable link, download link, view count, optional password, and optional expiration.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            settingsGroup("Recent uploads") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(appState.history.records.filter { $0.cloudShareURL != nil }.prefix(5)) { record in
                        HStack {
                            Text(record.displayName).lineLimit(1)
                            Spacer()
                            if let url = record.cloudShareURL {
                                Button("Copy Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                }
                            }
                        }
                    }
                    if !appState.history.records.contains(where: { $0.cloudShareURL != nil }) {
                        Text("No uploads yet").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var advanced: some View {
        settingsGroup("Permissions and storage") {
            VStack(alignment: .leading, spacing: 12) {
                permissionRow("Screen Recording", granted: screenRecordingGranted, pane: "Privacy_ScreenCapture")
                permissionRow("Accessibility", granted: accessibilityGranted, pane: "Privacy_Accessibility")
                Button("Check Again") { permissionRefresh += 1 }
                HStack {
                    Text("Application data")
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([appState.history.rootDirectory]) }
                }
            }
        }
    }

    private var about: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Screenshot").font(.system(size: 28, weight: .bold, design: .rounded))
            Text(versionString).foregroundStyle(.secondary)
            Text("Native capture, recording, annotation, OCR, history, pinning, and hosted sharing for macOS.")
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            content().padding(4)
        } label: {
            Text(title).font(.headline)
        }
        .frame(maxWidth: 620)
    }

    private func actionBinding(_ action: AfterCaptureAction) -> Binding<Bool> {
        Binding(
            get: { preferences.afterCaptureActions.contains(action) },
            set: { enabled in
                if enabled { preferences.afterCaptureActions.insert(action) }
                else { preferences.afterCaptureActions.remove(action) }
            }
        )
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).font(.system(.body, design: .rounded)).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)) }
            .padding(.vertical, 9)
    }

    private var captureAreaHint: String {
        if let shortcut = preferences.globalShortcuts.shortcut(for: .captureArea) {
            return "Try it: press \(shortcut.displayString) to capture an area, or open the menu bar icon."
        }
        return "Try it: open the menu bar icon and choose Capture Area."
    }

    private var screenRecordingGranted: Bool {
        _ = permissionRefresh
        return appState.captureService.hasScreenCaptureAccess
    }

    private var accessibilityGranted: Bool {
        _ = permissionRefresh
        return AXIsProcessTrusted()
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            if !granted {
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = preferences.exportDirectory
        if panel.runModal() == .OK, let url = panel.url { preferences.exportDirectory = url }
    }
}

/// Records a new global shortcut from the next key press in the Settings window. Global
/// shortcuts are unregistered while recording so the keys being recorded don't trigger them.
@MainActor
final class ShortcutRecorder: ObservableObject {
    struct Message {
        let action: GlobalShortcutAction
        let text: String
    }

    @Published private(set) var action: GlobalShortcutAction?
    @Published private(set) var pendingModifiers: NSEvent.ModifierFlags = []
    @Published private(set) var message: Message?

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var appState: AppState?

    func start(_ action: GlobalShortcutAction, appState: AppState) {
        stop()
        self.appState = appState
        self.action = action
        message = nil
        pendingModifiers = []
        appState.suspendGlobalShortcuts()
        // Local event monitors run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        // Clicking into another window or app ends recording and restores the shortcuts.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func show(_ text: String, for action: GlobalShortcutAction) {
        message = Message(action: action, text: text)
    }

    func clearMessage() {
        message = nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        pendingModifiers = []
        guard action != nil else { return }
        action = nil
        appState?.registerGlobalShortcuts()
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let action, let appState else { return false }
        let modifiers = event.modifierFlags.intersection(KeyShortcut.relevantModifiers)
        if event.type == .flagsChanged {
            pendingModifiers = modifiers
            return false
        }
        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            message = nil
            stop()
            return true
        }
        guard let shortcut = KeyShortcut(event: event) else { return true }
        guard shortcut.isAllowedAsGlobalShortcut else {
            message = Message(action: action, text: "\(shortcut.displayString) can't be a global shortcut. Include ⌃, or ⌘ together with ⌥ or ⇧.")
            return true
        }
        if let other = appState.preferences.globalShortcuts.action(using: shortcut, except: action) {
            message = Message(action: action, text: "\(shortcut.displayString) is already used by \(other.title).")
            return true
        }
        message = nil
        appState.preferences.globalShortcuts.set(shortcut, for: action)
        stop()
        return true
    }
}
