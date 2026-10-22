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
    private var companion: DriftCompanionController?
    private var driftSettingsWindow: DriftSettingsWindowController?

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
        let companion = DriftCompanionController(settings: DriftSettings(), store: store, capture: capture, captureSettings: settings,
                                                 classification: classification)
        let driftSettingsWindow = DriftSettingsWindowController(companion: companion)
        let statusMenu = StatusMenuController(settings: settings, capture: capture, store: store, classification: classification,
                                              companion: companion, showWelcome: { welcome.show() },
                                              showClassification: { classificationWindow.show() }, showReports: { reportsWindow.show() },
                                              showDriftSettings: { driftSettingsWindow.show() })
        companion.anchor = { statusMenu.anchorFrame() }
        companion.onChange = { statusMenu.refreshIcon(); driftSettingsWindow.refresh() }
        companion.settings.onChange = { companion.settingsChanged() }
        // Recording resuming may let a drift noticed meanwhile be offered, if it is still current.
        capture.onStateChange = { statusMenu.refreshIcon(); reportsWindow.refreshIfOpen(); companion.refresh() }
        // A removal recounts pending and failed blocks; the recount's onChange then refreshes both windows.
        capture.onActivityRemoved = { classification.refreshStatus() }
        // Excluded apps also decide what classification may send, so a change re-runs both.
        settings.onChange = { capture.tick(); classification.captureSettingsChanged() }
        classification.settings.onChange = { classification.settingsChanged(providerChanged: $0) }
        // Every run, correction, and removal reaches the ring and the drift rule through here.
        classification.onChange = { classificationWindow.model.refresh(); reportsWindow.refreshIfOpen(); companion.refresh() }
        self.capture = capture
        self.welcome = welcome
        self.statusMenu = statusMenu
        self.classification = classification
        self.classificationWindow = classificationWindow
        self.reportsWindow = reportsWindow
        self.companion = companion
        self.driftSettingsWindow = driftSettingsWindow
        capture.start()
        classification.start()
        companion.start()
        if !settings.onboardingCompleted { welcome.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture?.finishWrites()
    }
}
