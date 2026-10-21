import AppKit
import PointInTimeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = CaptureSettings()
    private var capture: CaptureController?
    private var statusMenu: StatusMenuController?
    private var welcome: WelcomeWindowController?
    private var classification: ClassificationController?
    private var classificationWindow: ClassificationWindowController?
    private var reportsWindow: ReportsWindowController?

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
        let classification = ClassificationController(settings: ClassificationSettings(), capture: settings, store: store,
                                                      deletionPending: { capture.hasPendingDeletion })
        let classificationWindow = ClassificationWindowController(controller: classification, store: store)
        let reportsWindow = ReportsWindowController(model: ReportsModel(store: store, storeError: storeError, classification: classification,
                                                                        captureState: { capture.state },
                                                                        showClassification: { classificationWindow.show() }))
        let statusMenu = StatusMenuController(settings: settings, capture: capture, store: store, classification: classification,
                                              showWelcome: { welcome.show() }, showClassification: { classificationWindow.show() },
                                              showReports: { reportsWindow.show() })
        capture.onStateChange = { statusMenu.refreshIcon(); reportsWindow.refreshIfOpen() }
        // A removal recounts pending and failed blocks; the recount's onChange then refreshes both windows.
        capture.onActivityRemoved = { classification.refreshStatus() }
        // Excluded apps also decide what classification may send, so a change re-runs both.
        settings.onChange = { capture.tick(); classification.captureSettingsChanged() }
        classification.settings.onChange = { classification.settingsChanged(providerChanged: $0) }
        classification.onChange = { classificationWindow.model.refresh(); reportsWindow.refreshIfOpen() }
        self.capture = capture
        self.welcome = welcome
        self.statusMenu = statusMenu
        self.classification = classification
        self.classificationWindow = classificationWindow
        self.reportsWindow = reportsWindow
        capture.start()
        classification.start()
        if !settings.onboardingCompleted { welcome.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture?.finishWrites()
    }
}
