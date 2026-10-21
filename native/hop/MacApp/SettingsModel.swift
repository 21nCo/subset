import AppKit
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

/// An excluded app as the Settings window lists it: its bundle ID, and the name and icon of the app installed under
/// it, when one is.
struct ExcludedApp: Identifiable, Equatable {
    var bundleIdentifier: String
    var name: String?
    var icon: NSImage?

    var id: String { bundleIdentifier }
}

/// Hop's settings while it runs: loads them at launch, saves each change at once and hands it to the app
/// (`onChange`), and holds what the Settings window shows besides them: the shortcut recorder, the login item and the
/// Accessibility permission.
///
/// Recording a shortcut takes every key press in Hop (a local event monitor) and asks the app to let every key through
/// the event tap (`onRecordingChange`) until it ends: with a new shortcut, Esc, Stop, or the Settings window closing or
/// losing focus. A press that is not an allowed shortcut keeps recording and shows why.
@MainActor
final class SettingsModel: ObservableObject {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "settings")

    @Published private(set) var settings: Settings
    @Published private(set) var isRecording = false
    /// Why the last press while recording was not taken, or nil.
    @Published private(set) var recorderMessage: String?
    @Published private(set) var loginItem: LoginItemStatus
    /// Why turning launch at login on or off failed, or nil.
    @Published private(set) var loginItemError: String?
    @Published var isAccessibilityTrusted = false

    /// Called after each change to the settings, once they are saved.
    var onChange: (Settings) -> Void = { _ in }
    /// Called when recording starts (true) and ends (false).
    var onRecordingChange: (Bool) -> Void = { _ in }

    private let store: SettingsStore
    private let loginItemService: any LoginItemService
    private var monitor: Any?

    init(store: SettingsStore = SettingsStore(), loginItemService: any LoginItemService = MainAppLoginItem()) {
        self.store = store
        self.loginItemService = loginItemService
        settings = store.load()
        loginItem = loginItemService.status
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

    /// Goes back to ⌥Tab, or shows why it can't (⌥Tab is the same-app shortcut).
    func resetShortcut() {
        stopRecording()
        var reset = settings
        do {
            try reset.resetShortcut()
            recorderMessage = nil
            update { $0 = reset }
        } catch {
            recorderMessage = error.reason
        }
    }

    /// Starts recording: the next allowed press becomes the shortcut.
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        recorderMessage = nil
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
        isRecording = false
        onRecordingChange(false)
    }

    /// Handles one key press while recording.
    func record(_ key: KeyEvent) {
        guard isRecording else { return }
        switch settings.record(key) {
        case let .recorded(shortcut):
            recorderMessage = nil
            update { try? $0.setShortcut(shortcut) }
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
}
