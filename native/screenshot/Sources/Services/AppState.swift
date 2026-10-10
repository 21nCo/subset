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
    /// Global shortcuts that macOS refused to register at launch.
    @Published var unavailableShortcuts: [String] = []
    var presentsErrors = true

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
                self.finishImage(image, kind: .area, forcedAction: action, allowsUpload: allowsUpload, source: source)
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
                self.finishImage(image, kind: .window, forcedAction: action, allowsUpload: allowsUpload, source: source)
            }
        }
    }

    func captureFullscreen(action: AfterCaptureAction? = nil, preferredDirectory: URL? = nil, allowsUpload: Bool = true) {
        let source = captureService.activeApplicationMetadata()
        Task {
            guard let image = await captureService.captureFullscreen() else {
                showError("Screen access is required before Screenshot can capture the display.")
                return
            }
            finishImage(image, kind: .fullscreen, forcedAction: action, preferredDirectory: preferredDirectory, allowsUpload: allowsUpload, source: source)
        }
    }

    func capturePreviousArea(action: AfterCaptureAction? = nil, allowsUpload: Bool = true) {
        let source = captureService.activeApplicationMetadata()
        Task {
            guard let image = await captureService.capturePreviousArea() else {
                showError("Capture an area first, then use Capture Previous Area.")
                return
            }
            finishImage(image, kind: .previousArea, forcedAction: action, allowsUpload: allowsUpload, source: source)
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
                    self.finishImage(image, kind: .area, forcedAction: nil, source: source)
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
                self.finishImage(image, kind: .scrolling, forcedAction: nil, allowsUpload: allowsUpload, source: source)
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
        regionController.select(mode: .recording) { [weak self] rect in
            guard let self, let rect else { return }
            Task { await self.beginRecording(area: rect, format: format) }
        }
    }

    func stopRecording() {
        Task {
            do {
                let result = try await recordingService.stop()
                tearDownRecordingUI()
                guard let result else { return }
                let record = try history.saveRecording(at: result.url, kind: result.format == .gif ? .gif : .recording, pixelSize: result.pixelSize)
                quickAccessController?.show(record: record, image: result.thumbnail)
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
        source: (application: String?, window: String?)
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
            if actions.contains(.quickAccess) { quickAccessController?.show(record: record, image: image) }
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
