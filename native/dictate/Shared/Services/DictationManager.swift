import AVFoundation
import Foundation
import SwiftUI
import AppKit
import ApplicationServices

@MainActor
final class DictationManager: ObservableObject {
    @Published var settings: DictationSettings
    @Published private(set) var transcriptState: SharedTranscriptState
    @Published private(set) var microphonePermission = "Unknown"
    @Published private(set) var microphoneLevel: Float = 0
    @Published var autoInsertFinalText = false
    @Published private(set) var localModelStatus = "Checking local whisper model..."
    @Published private(set) var isPreparingLocalModel = false
    /// True between the end of capture and the final transcript (and insertion) being ready.
    @Published private(set) var isFinalizing = false
    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var isLocalModelReady = false
    /// The most recent non-empty final transcript, kept after insertion so it can be copied again.
    @Published private(set) var lastTranscript = ""

    private let store: SharedTranscriptStore
    private var backend: (any DictationBackend)?
    private var streamingTask: Task<Void, Never>?
    private var insertionTarget: ActiveAppInsertionTarget?
    private var lastExternalInsertionTarget: ActiveAppInsertionApplicationTarget?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var isStoppingAndInserting = false
    private var isCancelling = false
    private var lastInsertedText = ""
    private var lastInsertedAt = Date.distantPast
    private var currentInsertSessionID: UUID?
    private var completedInsertSessions: [UUID: Date] = [:]

    init(store: SharedTranscriptStore = .shared) {
        self.store = store
        var loadedSettings = store.loadSettings()
        loadedSettings.backendKind = .whisperCppLocal
        loadedSettings.whisperModelPreset = .baseEn
        loadedSettings.useCoreML = true
        loadedSettings.localModelName = loadedSettings.whisperModelPreset.ggmlFilename
        self.settings = loadedSettings
        self.transcriptState = store.loadState()
        self.transcriptState.backendKind = .whisperCppLocal
        observeActiveApplications()
        refreshPermissionStatus()
        refreshLocalModelStatus()
    }

    func updateSettings(_ mutate: (inout DictationSettings) -> Void) {
        mutate(&settings)
        settings.backendKind = .whisperCppLocal
        settings.localModelName = settings.whisperModelPreset.ggmlFilename
        store.save(settings: settings)

        transcriptState.backendKind = .whisperCppLocal
        persistState(status: transcriptState.statusMessage)
        refreshLocalModelStatus()
    }

    func startDictation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !transcriptState.isRecording else { return }
            persistState(status: "Starting local dictation...")
            currentInsertSessionID = UUID()
            if insertionTarget == nil {
                insertionTarget = ActiveAppTextInjector.captureTarget()
                    ?? lastExternalInsertionTarget.map { ActiveAppInsertionTarget(application: $0, focusedElement: nil) }
            }
            guard await requestPermissionIfNeeded() else {
                persistState(status: "Microphone permission is required in the host app before dictation can start.")
                return
            }

            let backend = DictationBackendFactory.makeBackend(for: settings)
            self.backend = backend
            microphoneLevel = 0

            transcriptState = SharedTranscriptState(
                isRecording: true,
                startedAt: .now,
                backendKind: settings.backendKind,
                statusMessage: "\(backend.displayName) active in host app.",
                partialText: "",
                committedText: transcriptState.committedText,
                segments: transcriptState.segments,
                updatedAt: .now
            )
            store.save(state: transcriptState)

            let stream = backend.startStreaming(context: DictationContext(settings: settings))
            streamingTask?.cancel()
            streamingTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        await MainActor.run {
                            self?.consume(event)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self?.handleStreamError(error)
                    }
                }
            }
        }
    }

    /// Starts or stops dictation from a window or menu control (no hotkey held).
    /// Stopping from the UI keeps the transcript in Dictate instead of inserting it elsewhere.
    func toggleDictationFromUI() {
        if transcriptState.isRecording {
            stopDictation()
        } else {
            rememberInsertionTarget()
            startDictation()
        }
    }

    var menuBarStateDescription: String {
        if isFinalizing { return "Transcribing…" }
        if transcriptState.isRecording { return "Listening…" }
        return "Ready. Hold fn to dictate."
    }

    func rememberInsertionTarget() {
        insertionTarget = ActiveAppTextInjector.captureTarget()
            ?? lastExternalInsertionTarget.map { ActiveAppInsertionTarget(application: $0, focusedElement: nil) }
    }

    func stopDictation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isFinalizing = true
            defer { isFinalizing = false }
            await backend?.stopStreaming()
            await streamingTask?.value
            streamingTask = nil
            backend = nil
            let trimmed = transcriptState.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lastTranscript = trimmed
            }
            transcriptState.isRecording = false
            transcriptState.partialText = ""
            microphoneLevel = 0
            insertionTarget = nil
            currentInsertSessionID = nil
            persistState(status: "Dictation stopped.")
        }
    }

    func stopDictationAndInsert() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !isStoppingAndInserting, !isCancelling else { return }
            isStoppingAndInserting = true
            isFinalizing = true
            defer {
                isStoppingAndInserting = false
                isFinalizing = false
            }
            let insertSessionID = currentInsertSessionID

            await backend?.stopStreaming()
            await streamingTask?.value
            streamingTask = nil
            backend = nil
            transcriptState.isRecording = false
            transcriptState.partialText = ""

            let trimmed = transcriptState.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lastTranscript = trimmed
                await insertCommittedTextIntoActiveApp(sessionID: insertSessionID)
            } else {
                insertionTarget = nil
                persistState(status: "Dictation stopped.")
            }
            currentInsertSessionID = nil
        }
    }

    /// Ends the current session without inserting anything and discards its transcript.
    func cancelDictation() {
        guard transcriptState.isRecording, !isCancelling else { return }
        isCancelling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isCancelling = false }
            await backend?.stopStreaming()
            await streamingTask?.value
            streamingTask = nil
            backend = nil
            transcriptState.isRecording = false
            transcriptState.partialText = ""
            transcriptState.committedText = ""
            transcriptState.segments = []
            microphoneLevel = 0
            insertionTarget = nil
            currentInsertSessionID = nil
            persistState(status: "Dictation cancelled. Nothing was inserted.")
        }
    }

    /// Copies the most recent final transcript to the general pasteboard.
    @discardableResult
    func copyLastTranscript() -> Bool {
        let text = lastTranscript.isEmpty
            ? transcriptState.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
            : lastTranscript
        guard !text.isEmpty else {
            persistState(status: "Nothing to copy yet.")
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        persistState(status: "Copied the last transcript to the clipboard.")
        return true
    }

    /// Re-reads microphone, Accessibility, and local model state, e.g. when the app becomes active.
    func refreshSetupStatus() {
        refreshPermissionStatus()
        refreshLocalModelStatus()
    }

    func requestMicrophoneAccess() {
        Task { @MainActor [weak self] in
            _ = await self?.requestPermissionIfNeeded()
        }
    }

    /// Shows the system Accessibility prompt. The grant itself happens in System Settings.
    func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func openPrivacySettings(_ pane: PrivacyPane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }

    enum PrivacyPane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
    }

    func clearTranscript() {
        transcriptState.committedText = ""
        transcriptState.partialText = ""
        transcriptState.segments = []
        microphoneLevel = 0
        persistState(status: "Transcript buffer cleared.")
    }

    func insertCommittedTextIntoActiveApp(sessionID: UUID? = nil) async {
        let text = transcriptState.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            persistState(status: "Nothing to insert yet.")
            return
        }

        pruneCompletedInsertSessions()
        if let sessionID, completedInsertSessions[sessionID] != nil {
            persistState(status: "Skipped duplicate insert for the same dictation session.")
            return
        }

        if text == lastInsertedText, Date().timeIntervalSince(lastInsertedAt) < 3 {
            persistState(status: "Skipped duplicate insert for the same utterance.")
            return
        }

        let insertedIntoExternalApp = insertionTarget?.application?.processIdentifier != ProcessInfo.processInfo.processIdentifier

        do {
            if let sessionID {
                completedInsertSessions[sessionID] = Date()
            }
            lastInsertedText = text
            lastInsertedAt = Date()
            let method = try await ActiveAppTextInjector.insert(text: text, target: insertionTarget)
            insertionTarget = nil
            if insertedIntoExternalApp {
                transcriptState.committedText = ""
                transcriptState.partialText = ""
                transcriptState.segments.removeAll(keepingCapacity: false)
            }
            persistState(status: "Inserted final transcript into the active app via \(method.rawValue).")
        } catch {
            if let sessionID {
                completedInsertSessions.removeValue(forKey: sessionID)
            }
            persistState(status: error.localizedDescription)
        }
    }

    func prepareSelectedWhisperModel() {
        guard !isPreparingLocalModel else { return }

        isPreparingLocalModel = true
        localModelStatus = "Preparing \(settings.whisperModelPreset.title) whisper model..."

        Task { @MainActor [weak self] in
            guard let self else { return }
            let whisperModelManager = WhisperModelManager()

            do {
                _ = try await whisperModelManager.ensureLocalModel(for: settings) { [weak self] status in
                    Task { @MainActor [weak self] in
                        self?.localModelStatus = status
                    }
                }
                isPreparingLocalModel = false
                refreshLocalModelStatus()
            } catch {
                isPreparingLocalModel = false
                localModelStatus = error.localizedDescription
            }
        }
    }

    func revealWhisperModelsFolder() {
        do {
            let directoryURL = try WhisperModelStore().modelsDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
        } catch {
            localModelStatus = error.localizedDescription
        }
    }

    private func consume(_ event: TranscriptionEvent) {
        switch event {
        case .status(let message):
            persistState(status: message)
        case .partial(let text):
            transcriptState.partialText = text
            transcriptState.updatedAt = .now
            store.save(state: transcriptState)
        case .final(let text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }

            transcriptState.partialText = ""
            transcriptState.committedText = normalized
            transcriptState.segments = [TranscriptionSegment(text: normalized, isFinal: true)]
            persistState(status: "Final transcript committed for insertion.")
            if autoInsertFinalText {
                Task { @MainActor [weak self] in
                    await self?.insertCommittedTextIntoActiveApp()
                }
            }
        case .level(let level):
            microphoneLevel = level
        }
    }

    private func handleStreamError(_ error: Error) {
        transcriptState.isRecording = false
        microphoneLevel = 0
        insertionTarget = nil
        persistState(status: "Stream failed: \(error.localizedDescription)")
    }

    private func persistState(status: String) {
        transcriptState.statusMessage = status
        transcriptState.updatedAt = .now
        store.save(state: transcriptState)
    }

    private func refreshLocalModelStatus() {
        do {
            let whisperModelManager = WhisperModelManager()
            let snapshot = try whisperModelManager.snapshot(for: settings)
            localModelStatus = snapshot.statusDescription(coreMLEnabled: settings.useCoreML)
            isLocalModelReady = snapshot.modelURL != nil
        } catch {
            isLocalModelReady = false
            localModelStatus = error.localizedDescription
        }
    }

    private func refreshPermissionStatus() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermission = "Granted"
        case .denied, .restricted:
            microphonePermission = "Denied"
        case .notDetermined:
            microphonePermission = "Undetermined"
        @unknown default:
            microphonePermission = "Unknown"
        }
    }

    private func pruneCompletedInsertSessions() {
        let cutoff = Date().addingTimeInterval(-120)
        completedInsertSessions = completedInsertSessions.filter { $0.value >= cutoff }
    }

    private func observeActiveApplications() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else {
                return
            }

            Task { @MainActor [weak self] in
                self?.lastExternalInsertionTarget = ActiveAppInsertionApplicationTarget(application: application)
            }
        }
    }

    private func requestPermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshPermissionStatus()
            return true
        case .denied, .restricted:
            refreshPermissionStatus()
            return false
        case .notDetermined:
            let granted = await Self.requestMicrophoneAccess()
            refreshPermissionStatus()
            return granted
        @unknown default:
            refreshPermissionStatus()
            return false
        }
    }

    nonisolated private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
