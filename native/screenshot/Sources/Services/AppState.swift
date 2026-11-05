import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    let preferences = AppPreferences.shared
    let history = HistoryStore.shared
    let captureService = ScreenCaptureService()
    let ocrService = OCRService()
    let cloudService = CloudShareService()

    lazy var regionController = RegionCaptureController(screenCaptureService: captureService)
    lazy var scrollingService = ScrollingCaptureService(captureService: captureService)
    lazy var recordingService = ScreenRecordingService()

    var quickAccessController: QuickAccessPanelController?
    var editorController: EditorWindowController?
    var historyController: HistoryWindowController?
    var pinController: PinWindowController?
    var recordingControlsController: RecordingControlsPanelController?
    var cameraController: CameraOverlayController?
    var inputOverlayController: InputOverlayController?
    var videoEditorController: VideoEditorWindowController?
    var settingsOpener: ((SettingsTab) -> Void)?

    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastError: String?
    @Published var uploadProgress: Double?
    /// Global shortcuts that macOS refused to register, usually because another app owns them.
    @Published var unavailableShortcuts: Set<GlobalShortcutAction> = []
    /// True while Settings records a new shortcut; global shortcuts are unregistered meanwhile
    /// so the keys being recorded don't trigger a capture.
    private(set) var globalShortcutsSuspended = false
    /// The area being recorded, so Quick Access opens on that display when recording stops.
    private var recordingArea: CGRect?
    /// From the chosen recording area until the recording has started (or failed).
    private var isStartingRecording = false
    /// From a stop request until the recording is saved; a second stop is ignored.
    private var isStoppingRecording = false
    var presentsErrors = true

    /// Registers the current global shortcut bindings, replacing earlier registrations, and
    /// returns the actions macOS refused.
    @discardableResult
    func registerGlobalShortcuts() -> Set<GlobalShortcutAction> {
        globalShortcutsSuspended = false
        let registrations = GlobalShortcutAction.allCases.compactMap { action -> ShortcutRegistration? in
            guard let shortcut = preferences.globalShortcuts.shortcut(for: action) else { return nil }
            return ShortcutRegistration(
                id: action.hotKeyID,
                name: "\(action.title) (\(shortcut.displayString))",
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                handler: { [weak self] in self?.perform(action) }
            )
        }
        let failedIDs = Set(GlobalShortcutMonitor.shared.start(registrations))
        unavailableShortcuts = Set(GlobalShortcutAction.allCases.filter { failedIDs.contains($0.hotKeyID) })
        return unavailableShortcuts
    }

    func suspendGlobalShortcuts() {
        globalShortcutsSuspended = true
        GlobalShortcutMonitor.shared.stop()
    }

    func perform(_ action: GlobalShortcutAction) {
        switch action {
        case .captureArea: captureArea()
        case .captureWindow: captureWindow()
        // Like the menu item, the shortcut stops a recording that is running.
        case .recordScreen: isRecording ? stopRecording() : startRecording()
        case .captureText: captureText()
        case .captureHistory: openHistory()
        }
    }

    func captureArea(action: AfterCaptureAction? = nil, allowsUpload: Bool = true) {
        // Read the source app before the selection overlay activates Screenshot.
        let source = captureService.activeApplicationMetadata()
        regionController.select(mode: .area) { [weak self] rect in
            guard let self, let rect else { return }
            Task {
                guard let image = await self.captureService.capture(area: rect) else {
                    self.showError(Self.captureFailedMessage)
                    return
                }
                self.finishImage(image, kind: .area, forcedAction: action, allowsUpload: allowsUpload, source: source, area: rect)
            }
        }
    }

    func captureWindow(action: AfterCaptureAction? = nil, allowsUpload: Bool = true) {
        let source = captureService.activeApplicationMetadata()
        regionController.select(mode: .window) { [weak self] rect in
            guard let self, let rect else { return }
            Task {
                guard let image = await self.captureService.capture(area: rect) else {
                    self.showError(Self.captureFailedMessage)
                    return
                }
                self.finishImage(image, kind: .window, forcedAction: action, allowsUpload: allowsUpload, source: source, area: rect)
            }
        }
    }

    func captureFullscreen(action: AfterCaptureAction? = nil, preferredDirectory: URL? = nil, allowsUpload: Bool = true) {
        let source = captureService.activeApplicationMetadata()
        // Pick the display now, so moving the pointer during the capture changes neither the
        // captured display nor where Quick Access opens.
        let screen = ScreenCaptureService.screenUnderPointer()
        let displayID = screen.flatMap(ScreenCaptureService.displayID(of:))
        Task {
            guard let image = await captureService.captureFullscreen(displayID: displayID) else {
                showError("Screen access is required before Screenshot can capture the display.")
                return
            }
            finishImage(image, kind: .fullscreen, forcedAction: action, preferredDirectory: preferredDirectory, allowsUpload: allowsUpload, source: source, area: screen?.frame)
        }
    }

    func capturePreviousArea(action: AfterCaptureAction? = nil, allowsUpload: Bool = true) {
        let source = captureService.activeApplicationMetadata()
        // Read the area once: a capture finishing meanwhile replaces previousArea.
        guard let area = captureService.previousArea else {
            showError("Capture an area first, then use Capture Previous Area.")
            return
        }
        Task {
            guard let image = await captureService.capture(area: area, remember: false) else {
                showError(Self.captureFailedMessage)
                return
            }
            finishImage(image, kind: .previousArea, forcedAction: action, allowsUpload: allowsUpload, source: source, area: area)
        }
    }

    func captureWithTimer(seconds: Int = 5) {
        let source = captureService.activeApplicationMetadata()
        regionController.select(mode: .area) { [weak self] rect in
            guard let self, let rect else { return }
            SelfTimerOverlay.shared.start(seconds: seconds) { [weak self] in
                guard let self else { return }
                Task {
                    guard let image = await self.captureService.capture(area: rect) else {
                        self.showError(Self.captureFailedMessage)
                        return
                    }
                    self.finishImage(image, kind: .area, forcedAction: nil, source: source, area: rect)
                }
            }
        }
    }

    func captureScrolling(allowsUpload: Bool = true) {
        let source = captureService.activeApplicationMetadata()
        regionController.select(mode: .scrolling) { [weak self] rect in
            guard let self, let rect else { return }
            Task {
                guard let image = await self.scrollingService.capture(area: rect) else {
                    self.showError("Automatic scrolling needs Accessibility and Screen Recording permission.")
                    return
                }
                self.finishImage(image, kind: .scrolling, forcedAction: nil, allowsUpload: allowsUpload, source: source, area: rect)
            }
        }
    }

    func captureText(preserveLineBreaks: Bool = true) {
        regionController.select(mode: .text) { [weak self] rect in
            guard let self, let rect else { return }
            Task {
                guard let image = await self.captureService.capture(area: rect, remember: false) else {
                    self.showError(Self.captureFailedMessage)
                    return
                }
                do {
                    let result = try await self.ocrService.recognize(image: image, preserveLineBreaks: preserveLineBreaks)
                    // Leave the user's clipboard alone when nothing was recognized.
                    guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.showError("No text was recognized in the selected area.")
                        return
                    }
                    self.ocrService.copyToClipboard(result.text)
                    OCRResultPanel.shared.show(text: result.text)
                } catch {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func startRecording(format: RecordingFormat = .mp4) {
        // A recording already starting or stopping ignores another Record request.
        guard !isRecording, !isStartingRecording, !isStoppingRecording else { return }
        regionController.select(mode: .recording) { [weak self] rect in
            guard let self, let rect, !self.isRecording, !self.isStartingRecording, !self.isStoppingRecording else { return }
            self.isStartingRecording = true
            Task {
                await self.beginRecording(area: rect, format: format)
                self.isStartingRecording = false
            }
        }
    }

    func stopRecording() {
        guard !isStoppingRecording else { return }
        isStoppingRecording = true
        // Read before awaiting: a new recording may start before this one is saved.
        let area = recordingArea
        Task {
            defer { isStoppingRecording = false }
            do {
                let result = try await recordingService.stop()
                tearDownRecordingUI()
                guard let result else { return }
                let record = try history.saveRecording(at: result.url, kind: result.format == .gif ? .gif : .recording, pixelSize: result.pixelSize)
                quickAccessController?.show(record: record, image: result.thumbnail, near: area)
                if preferences.openVideoEditor, result.format == .mp4 {
                    videoEditorController?.show(url: result.url)
                }
                reportHistoryPersistenceError()
            } catch {
                tearDownRecordingUI()
                showError(error.localizedDescription)
            }
        }
    }

    private func tearDownRecordingUI() {
        isRecording = false
        recordingDuration = 0
        recordingControlsController?.hide()
        cameraController?.hide()
        inputOverlayController?.stop()
    }

    func recordFullscreen(
        duration: TimeInterval,
        preferredDirectory: URL? = nil,
        format: RecordingFormat = .mp4
    ) {
        guard let screen = NSScreen.main else {
            showError("No display is available for recording.")
            return
        }
        let directory = preferredDirectory ?? preferences.exportDirectory
        let destination = HistoryStore.uniqueURL(
            in: directory,
            fileName: preferences.formattedFileName(suffix: "Recording") + ".mp4",
            reservingExtensions: format == .gif ? ["gif"] : []
        )

        Task {
            do {
                try await recordingService.start(area: screen.frame, destination: destination, format: format, preferences: preferences)
                isRecording = true
                try await Task.sleep(for: .seconds(duration))
                let result = try await recordingService.stop()
                isRecording = false
                guard let result else { return }
                _ = try history.saveRecording(
                    at: result.url,
                    kind: result.format == .gif ? .gif : .recording,
                    pixelSize: result.pixelSize
                )
                reportHistoryPersistenceError()
            } catch {
                isRecording = false
                showError(error.localizedDescription)
            }
        }
    }

    func toggleRecordingPause() {
        recordingService.togglePause()
    }

    func openHistory() {
        historyController?.show()
    }

    func restoreMostRecent() {
        guard let record = history.restoreMostRecent() else {
            showError("There are no recent captures to restore.")
            return
        }
        if let image = NSImage(contentsOf: record.fileURL) ?? record.thumbnailURL.flatMap(NSImage.init(contentsOf:)) {
            quickAccessController?.show(record: record, image: image)
        }
    }

    func openEditor(record: CaptureRecord) {
        let url = FileManager.default.fileExists(atPath: record.fileURL.path) ? record.fileURL : record.thumbnailURL
        guard let url, let image = NSImage(contentsOf: url) else { return }
        editorController?.show(image: image, record: record)
    }

    func openEditor(image: NSImage, record: CaptureRecord? = nil) {
        editorController?.show(image: image, record: record)
    }

    func pin(record: CaptureRecord) {
        let url = FileManager.default.fileExists(atPath: record.fileURL.path) ? record.fileURL : record.thumbnailURL
        guard let url, let image = NSImage(contentsOf: url) else { return }
        pinController?.pin(image: image, title: record.displayName)
    }

    func upload(record: CaptureRecord) {
        uploadProgress = 0
        Task {
            do {
                let response = try await cloudService.upload(record: record, preferences: preferences)
                history.updateCloud(id: record.id, shareURL: response.shareURL, cloudID: response.id)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(response.shareURL.absoluteString, forType: .string)
                uploadProgress = 1
                quickAccessController?.markUploaded(recordID: record.id, url: response.shareURL)
            } catch {
                uploadProgress = nil
                showError(error.localizedDescription)
            }
        }
    }

    func updateShare(
        record: CaptureRecord,
        password: ShareFieldChange<String>,
        expiresAt: ShareFieldChange<Date>,
        tags: [String]
    ) async throws {
        guard let cloudID = record.cloudID else { return }
        try await cloudService.update(
            id: cloudID,
            password: password,
            expiresAt: expiresAt,
            tags: tags,
            preferences: preferences
        )
        history.updateTags(id: record.id, tags: tags)
    }

    func deleteShare(record: CaptureRecord) async throws {
        guard let cloudID = record.cloudID else { return }
        try await cloudService.delete(id: cloudID, preferences: preferences)
        history.clearCloud(id: record.id)
    }

    func copy(record: CaptureRecord) {
        guard let image = NSImage(contentsOf: record.fileURL) ?? record.thumbnailURL.flatMap(NSImage.init(contentsOf:)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    func showSettings(_ tab: SettingsTab = .general) {
        preferences.selectedSettingsTab = tab
        settingsOpener?(tab)
    }

    private func beginRecording(area: CGRect, format: RecordingFormat) async {
        do {
            // Both formats record to an MP4 first; GIF is converted from it when recording stops.
            // A unique name keeps earlier recordings (and their history entries) intact.
            let destination = HistoryStore.uniqueURL(
                in: preferences.exportDirectory,
                fileName: preferences.formattedFileName() + ".mp4",
                reservingExtensions: format == .gif ? ["gif"] : []
            )
            recordingService.onUnexpectedStop = { [weak self] in self?.stopRecording() }
            try await recordingService.start(area: area, destination: destination, format: format, preferences: preferences)
            recordingArea = area
            isRecording = true
            if preferences.showRecordingControls { recordingControlsController?.show(area: area) }
            if preferences.showCamera { cameraController?.show() }
            if preferences.showKeystrokes || preferences.highlightClicks {
                inputOverlayController?.start(
                    showKeystrokes: preferences.showKeystrokes,
                    highlightClicks: preferences.highlightClicks,
                    area: area
                )
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func finishImage(
        _ image: NSImage,
        kind: CaptureKind,
        forcedAction: AfterCaptureAction?,
        preferredDirectory: URL? = nil,
        allowsUpload: Bool = true,
        source: (application: String?, window: String?),
        area: CGRect? = nil
    ) {
        do {
            var actions = forcedAction.map { Set([$0]) } ?? preferences.afterCaptureActions
            if !allowsUpload { actions.remove(.upload) }
            let record = try history.saveImage(
                image,
                kind: kind,
                preferredDirectory: preferredDirectory,
                // An explicit directory (automation) always saves; otherwise honor the Save action.
                savesToExportLocation: actions.contains(.save) || preferredDirectory != nil,
                sourceApplication: source.application,
                sourceWindow: source.window
            )
            if actions.contains(.copy) { copy(record: record) }
            if actions.contains(.annotate) { openEditor(image: image, record: record) }
            if actions.contains(.upload) { upload(record: record) }
            if actions.contains(.pin) { pinController?.pin(image: image, title: record.displayName) }
            if actions.contains(.quickAccess) { quickAccessController?.show(record: record, image: image, near: area) }
            reportHistoryPersistenceError()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private static let captureFailedMessage = "The capture failed. Check that Screenshot has Screen Recording permission in System Settings > Privacy & Security."

    private func reportHistoryPersistenceError() {
        if let message = history.persistenceError { showError(message) }
    }

    func showError(_ message: String) {
        lastError = message
        guard presentsErrors else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screenshot"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
