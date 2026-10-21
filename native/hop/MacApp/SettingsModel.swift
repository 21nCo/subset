import AppKit
import ApplicationServices
import HopCore
import os
import ServiceManagement
import UniformTypeIdentifiers

/// Launch at login, as the Settings window needs it. `MainAppLoginItem` is the live one.
@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    /// Opens System Settings > General > Login Items.
    func openSettings()
}

/// Hop itself as a login item, through `SMAppService.mainApp`.
struct MainAppLoginItem: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The Accessibility pane as the Permissions section opens it. `live` is the real one; tests replace it.
struct AccessibilityPane {
    var isTrusted: () -> Bool
    /// Asks with the prompt option, so macOS lists Hop in the pane.
    var prompt: () -> Void
    var open: (URL) -> Void

    @MainActor static let live = AccessibilityPane(
        isTrusted: { AXIsProcessTrusted() },
        prompt: { AccessibilityPermission.prompt() },
        open: { NSWorkspace.shared.open($0) }
    )
}

/// An excluded app as the Settings window lists it: its bundle ID, and the name and icon of the app installed under
/// it, when one is.
struct ExcludedApp: Identifiable, Equatable {
    var bundleIdentifier: String
    var name: String?
    var icon: NSImage?

    var id: String { bundleIdentifier }
}

/// Hop's settings while it runs: loads them at launch, saves each change at once and hands it to the app
/// (`onChange`), and holds what the Settings window shows besides them: the shortcut recorder, the login item, and the
/// Accessibility and Screen Recording permissions.
///
/// Recording a shortcut (the switch shortcut or the same-app shortcut) takes every key press in Hop (a local event
/// monitor) and asks the app to let every key through the event tap (`onRecordingChange`) until it ends: with a new
/// shortcut, Esc, Stop, or the Settings window closing or losing focus. A press that is not an allowed shortcut, or
/// that is the other shortcut, keeps recording and shows why.
@MainActor
final class SettingsModel: ObservableObject {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "settings")

    @Published private(set) var settings: Settings
    /// The shortcut being recorded, or nil.
    @Published private(set) var recording: ShortcutRole?
    /// Why the last press while recording, or the last reset, was not taken, or nil.
    @Published private(set) var recorderMessage: String?
    /// The shortcut `recorderMessage` is about.
    @Published private(set) var recorderMessageRole = ShortcutRole.switchWindows
    @Published private(set) var loginItem: LoginItemStatus
    /// Why turning launch at login on or off failed, or nil.
    @Published private(set) var loginItemError: String?
    @Published var isAccessibilityTrusted = false
    /// The Screen Recording permission as last sampled; window previews need it.
    @Published private(set) var screenRecording = ScreenRecordingAccess.notDetermined

    /// Called after each change to the settings, once they are saved.
    var onChange: (Settings) -> Void = { _ in }
    /// Called when recording starts (true) and ends (false).
    var onRecordingChange: (Bool) -> Void = { _ in }
    /// Called after each sample that finds Screen Recording not granted, wherever it was taken (the Settings window,
    /// Hop becoming active, a switcher opening), so the switcher drops every thumbnail at once.
    var onScreenRecordingNotGranted: () -> Void = {}

    private let store: SettingsStore
    private let loginItemService: any LoginItemService
    private let accessibilityPane: AccessibilityPane
    private let screenRecordingPane: ScreenRecordingPane
    private var screenRecordingGate = ScreenRecordingGate()
    private var monitor: Any?

    init(
        store: SettingsStore = SettingsStore(),
        loginItemService: any LoginItemService = MainAppLoginItem(),
        accessibilityPane: AccessibilityPane = .live,
        screenRecordingPane: ScreenRecordingPane = .live
    ) {
        self.store = store
        self.loginItemService = loginItemService
        self.accessibilityPane = accessibilityPane
        self.screenRecordingPane = screenRecordingPane
        settings = store.load()
        loginItem = loginItemService.status
        refreshScreenRecording()
    }

    /// Applies a change, saves it and tells the app. Nothing happens when it changes nothing.
    func update(_ change: (inout Settings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        store.save(updated)
        onChange(updated)
    }

    // MARK: - Shortcut

    var isRecording: Bool { recording != nil }

    /// Goes back to the default (⌥Tab, or ⌥` for the same-app shortcut), or shows why it can't (it is the other
    /// shortcut).
    func resetShortcut(_ role: ShortcutRole = .switchWindows) {
        stopRecording()
        var reset = settings
        recorderMessageRole = role
        do {
            try reset.resetShortcut(role)
            recorderMessage = nil
            update { $0 = reset }
        } catch {
            recorderMessage = error.reason
        }
    }

    /// Starts recording `role`: the next allowed press becomes that shortcut. While another one is being recorded,
    /// recording moves to `role`.
    func startRecording(_ role: ShortcutRole = .switchWindows) {
        guard recording != role else { return }
        recorderMessage = nil
        recorderMessageRole = role
        guard recording == nil else {
            recording = role
            return
        }
        recording = role
        onRecordingChange(true)
        // Local monitors run on the main thread, before the event reaches a window.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = KeyEvent(
                .keyDown,
                keyCode: event.keyCode,
                modifiers: ModifierMask(eventFlags: UInt64(event.modifierFlags.rawValue)),
                isRepeat: event.isARepeat
            )
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isRecording else { return false }
                self.record(key)
                return true
            }
            return taken ? nil : event
        }
    }

    /// Ends recording and keeps the shortcut as it is.
    func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        onRecordingChange(false)
    }

    /// Handles one key press while recording.
    func record(_ key: KeyEvent) {
        guard let role = recording else { return }
        switch settings.record(key, for: role) {
        case let .recorded(shortcut):
            recorderMessage = nil
            update { try? $0.setShortcut(shortcut, for: role) }
            stopRecording()
            Self.log.info("Shortcut recorded: \(shortcut.displayName, privacy: .public)")
        case let .rejected(reason):
            recorderMessage = reason.reason
        case .cancelled:
            recorderMessage = nil
            stopRecording()
        case .ignored:
            break
        }
    }

    // MARK: - Excluded apps

    var excludedApps: [ExcludedApp] {
        settings.excludedApps.map { bundleIdentifier in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            return ExcludedApp(
                bundleIdentifier: bundleIdentifier,
                name: url.map { $0.deletingPathExtension().lastPathComponent },
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            )
        }
    }

    /// Running apps with a Dock icon that are not excluded yet, by name, for the Add Running App menu.
    var runningAppsToExclude: [(bundleIdentifier: String, name: String)] {
        var seen = Set(settings.excludedApps + [HopIdentity.bundleIdentifier])
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleIdentifier = app.bundleIdentifier, seen.insert(bundleIdentifier).inserted else { return nil }
                return (bundleIdentifier, app.localizedName ?? bundleIdentifier)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func exclude(_ bundleIdentifier: String) {
        update { $0.exclude(bundleIdentifier) }
    }

    func include(_ bundleIdentifier: String) {
        update { $0.include(bundleIdentifier) }
    }

    /// Lets the user pick apps in /Applications to exclude. An app without a bundle ID cannot be excluded.
    func chooseAppsToExclude() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Exclude"
        panel.message = "Choose apps whose windows Hop never shows."
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            MainActor.assumeIsolated {
                for bundleIdentifier in identifiers { self?.exclude(bundleIdentifier) }
            }
        }
    }

    // MARK: - Launch at login

    func refreshLoginItem() {
        loginItem = loginItemService.status
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try loginItemService.register() } else { try loginItemService.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't turn \(on ? "on" : "off") launch at login: \(error.localizedDescription)"
            Self.log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshLoginItem()
    }

    func openLoginItems() {
        loginItemService.openSettings()
    }

    // MARK: - Window previews

    /// Turns window previews on or off. Turning them on asks for Screen Recording unless Hop has it; macOS shows its
    /// prompt then, never while switching.
    func setShowWindowPreviews(_ on: Bool) {
        update { $0.showWindowPreviews = on }
        if on, !screenRecordingPane.isGranted() { screenRecordingPane.request() }
        refreshScreenRecording()
    }

    /// Samples the Screen Recording permission, without prompting. A sample that finds it not granted tells the app
    /// (`onScreenRecordingNotGranted`), even when it was already not granted.
    @discardableResult
    func refreshScreenRecording() -> ScreenRecordingAccess {
        let access = screenRecordingGate.update(
            granted: screenRecordingPane.isGranted(),
            requested: screenRecordingPane.wasRequested()
        )
        if access != screenRecording { screenRecording = access }
        if access != .granted { onScreenRecordingNotGranted() }
        return access
    }

    /// Whether a switcher opening now captures thumbnails: previews are on and Screen Recording is granted. Samples the
    /// permission without prompting, so a revocation noticed here shows in the Settings window too.
    func capturesThumbnails() -> Bool {
        guard settings.showWindowPreviews else { return false }
        return ScreenRecordingGate.captures(previewsOn: true, access: refreshScreenRecording())
    }

    /// Opens Privacy & Security > Screen Recording. When Hop is not allowed yet, it asks first so Hop is listed there.
    func openScreenRecordingSettings() {
        if !screenRecordingPane.isGranted() { screenRecordingPane.request() }
        screenRecordingPane.open(ScreenRecordingPane.settingsURL)
        refreshScreenRecording()
    }

    // MARK: - Permissions

    /// Opens Privacy & Security > Accessibility whether or not Hop is allowed, so the button works in both states.
    /// When Hop is not allowed yet, it asks with the prompt option first so Hop is listed there.
    func openAccessibilitySettings() {
        if !accessibilityPane.isTrusted() {
            accessibilityPane.prompt()
        }
        accessibilityPane.open(AccessibilityPermission.settingsURL)
    }
}
