import AppKit
import PointInTimeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = CaptureSettings()
    private var capture: CaptureController?
    private var statusMenu: StatusMenuController?
    private var welcome: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        var store: ActivityStore?
        var storeError: String?
        do {
            store = try ActivityStore(directory: try ActivityStore.defaultDirectory())
        } catch {
            // A damaged or newer store is left untouched; tracking stays unavailable and the menu says why.
            storeError = String(describing: error)
        }
        let capture = CaptureController(settings: settings, store: store, storeError: storeError)
        let welcome = WelcomeWindowController(settings: settings) { capture.tick() }
        let statusMenu = StatusMenuController(settings: settings, capture: capture, store: store) { welcome.show() }
        capture.onStateChange = { statusMenu.refreshIcon() }
        settings.onChange = { capture.tick() }
        self.capture = capture
        self.welcome = welcome
        self.statusMenu = statusMenu
        capture.start()
        if !settings.onboardingCompleted { welcome.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture?.finishWrites()
    }
}
