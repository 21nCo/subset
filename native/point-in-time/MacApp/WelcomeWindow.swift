import AppKit
import SwiftUI

/// First-run explanation of what is captured and where it is kept, with the optional permission requests.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private var model: WelcomeModel?
    private var closeObserver: NSObjectProtocol?
    private let settings: CaptureSettings
    private let onStart: () -> Void

    init(settings: CaptureSettings, onStart: @escaping () -> Void) {
        self.settings = settings
        self.onStart = onStart
    }

    func show() {
        if window == nil {
            let model = WelcomeModel(settings: settings)
            let view = WelcomeView(model: model, onStart: { [weak self] in
                self?.onStart()
                self?.window?.close()
            })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to pointInTime"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { model.stopPolling() }
            }
            self.model = model
            self.window = window
        }
        model?.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class WelcomeModel: ObservableObject {
    @Published var accessibilityGranted = AccessibilityAccess.isGranted
    @Published var browserStatus: [SupportedBrowser: AutomationPermission] = [:]
    let settings: CaptureSettings
    let browsers = SupportedBrowser.installed
    private var timer: Timer?

    init(settings: CaptureSettings) {
        self.settings = settings
    }

    /// Accessibility is granted in System Settings, so poll while the window is open.
    func startPolling() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessibilityGranted = AccessibilityAccess.isGranted }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        accessibilityGranted = AccessibilityAccess.isGranted
        for browser in browsers { checkBrowser(browser, ask: false) }
    }

    /// The consent prompt can block, so it is requested off the main thread. macOS only prompts while the browser is
    /// running; it is launched in the background first if needed.
    func checkBrowser(_ browser: SupportedBrowser, ask: Bool) {
        Task.detached {
            if ask, NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(for: .seconds(2))
            }
            let status = ActivityReader.permission(for: browser.bundleID, ask: ask)
            await MainActor.run { self.browserStatus[browser] = status }
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("pointInTime records which app, window, and website is in front while you work, in three-minute blocks, so you can see where your day went.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("Recorded: the app’s name, its focused window title, and for Chrome, Brave, Edge, Arc, Vivaldi, and Aside the site and page path. Query strings and idle time are not recorded. An excluded app’s name, title, and site are never recorded; its time is kept as anonymous excluded time unless you choose Record Nothing.", systemImage: "list.bullet.rectangle")
                Label("Stored only on this Mac in ~/Library/Application Support/pointInTime. Nothing is sent anywhere.", systemImage: "lock.laptopcomputer")
                Label("Pause, exclude an app, or delete data any time from the menu bar.", systemImage: "menubar.rectangle")
            }
            .fixedSize(horizontal: false, vertical: true)

            GroupBox("Optional permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Window titles (Accessibility)")
                        Spacer()
                        if model.accessibilityGranted {
                            Text("Granted").foregroundStyle(.secondary)
                        } else {
                            Button("Grant…") { AccessibilityAccess.request() }
                        }
                    }
                    ForEach(model.browsers, id: \.self) { browser in
                        HStack {
                            Text("Sites in \(browser.name) (Automation)")
                            Spacer()
                            switch model.browserStatus[browser] {
                            case .granted: Text("Allowed").foregroundStyle(.secondary)
                            case .denied: Text("Denied in System Settings > Privacy & Security > Automation").foregroundStyle(.secondary).font(.caption)
                            default: Button("Allow…") { model.checkBrowser(browser, ask: true) }
                            }
                        }
                    }
                    Text("In Chrome, Brave, Edge, Arc, Vivaldi, and Aside, a window’s title and site are kept only after you allow Automation and the browser confirms the window is not private or incognito; otherwise only the browser’s name is recorded. Safari is recorded by app and window title, never a site, and its private-browsing window titles are dropped. Every other browser, including Firefox and other Chrome or Edge channels, is recorded by app name only. Other apps are recorded by app and window title.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button(model.settings.onboardingCompleted ? "Done" : "Start Tracking") {
                    if !model.settings.onboardingCompleted {
                        model.settings.trackingEnabled = true
                        model.settings.onboardingCompleted = true
                    }
                    onStart()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
