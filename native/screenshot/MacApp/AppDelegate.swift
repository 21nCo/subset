import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appState = AppState()
    private var statusMenuController: StatusMenuController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        appState.quickAccessController = QuickAccessPanelController(appState: appState)
        appState.editorController = EditorWindowController(appState: appState)
        appState.historyController = HistoryWindowController(appState: appState)
        appState.pinController = PinWindowController(appState: appState)
        appState.recordingControlsController = RecordingControlsPanelController(appState: appState)
        appState.cameraController = CameraOverlayController()
        appState.inputOverlayController = InputOverlayController()
        appState.videoEditorController = VideoEditorWindowController()
        appState.settingsOpener = { [weak self] tab in self?.showSettings(tab: tab) }
        statusMenuController = StatusMenuController(appState: appState)

        // macOS 15 rejects hot keys whose only modifiers are Option or Option-Shift, so every
        // default includes Control. Failures are reported instead of silently dropped.
        let failedShortcuts = GlobalShortcutMonitor.shared.start([
            ShortcutRegistration(id: 1, name: "Capture Area (⌃⌥S)", keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), handler: { [weak self] in self?.appState.captureArea() }),
            ShortcutRegistration(id: 2, name: "Capture Window (⌃⌥⇧S)", keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | shiftKey), handler: { [weak self] in self?.appState.captureWindow() }),
            ShortcutRegistration(id: 3, name: "Record Screen (⌃⌥⇧R)", keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | shiftKey), handler: { [weak self] in self?.appState.startRecording() }),
            ShortcutRegistration(id: 4, name: "Capture Text (⌃⌥⇧O)", keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey | shiftKey), handler: { [weak self] in self?.appState.captureText() }),
            ShortcutRegistration(id: 5, name: "Capture History (⌃⌥⇧H)", keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey | shiftKey), handler: { [weak self] in self?.appState.openHistory() })
        ])
        appState.unavailableShortcuts = failedShortcuts
        if !failedShortcuts.isEmpty, ProcessInfo.processInfo.arguments.count <= 1 {
            DispatchQueue.main.async { [weak self] in
                self?.appState.showError("These global shortcuts could not be registered, usually because another app already uses them: \(failedShortcuts.joined(separator: ", ")). Use the menu bar icon instead.")
            }
        }

        let arguments = ProcessInfo.processInfo.arguments
        handleLaunchActions(arguments)
        showOnboardingIfNeeded(arguments: arguments)
        if let settingsArgument = arguments.first(where: { $0.hasPrefix("--settings") }) {
            let rawTab = settingsArgument.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
            let tab = rawTab.flatMap(SettingsTab.init(rawValue:)) ?? .general
            DispatchQueue.main.async { [weak self] in
                self?.showSettings(tab: tab)
                guard let snapshotArgument = arguments.first(where: { $0.hasPrefix("--snapshot=") }),
                      let path = snapshotArgument.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let window = self?.settingsWindow else { return }
                    self?.saveWindowSnapshot(window, to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// First launch without Screen Recording permission opens General settings, which explains
    /// the permission and links to System Settings. Automation launches (any argument) skip it.
    private func showOnboardingIfNeeded(arguments: [String]) {
        guard arguments.count <= 1, !appState.preferences.hasCompletedOnboarding,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        appState.preferences.hasCompletedOnboarding = true
        guard !appState.captureService.hasScreenCaptureAccess else { return }
        DispatchQueue.main.async { [weak self] in self?.showSettings(tab: .general) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalShortcutMonitor.shared.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handleActionURL)
    }

    func showSettings(tab: SettingsTab) {
        appState.preferences.selectedSettingsTab = tab
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Screenshot Settings"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 540)
            window.contentView = NSHostingView(rootView: SettingsView(appState: appState))
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleLaunchActions(_ arguments: [String]) {
        let value: (String) -> String? = { name in
            arguments.first(where: { $0.hasPrefix("--\(name)=") })?
                .split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
        }

        if let captureArgument = arguments.first(where: { $0 == "--capture-fullscreen" || $0.hasPrefix("--capture-fullscreen=") }) {
            appState.presentsErrors = false
            appState.lastError = nil
            let baselineRecordIDs = Set(appState.history.records.map(\.id))
            let rawAction = captureArgument.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
            let action = rawAction.flatMap(AfterCaptureAction.init(rawValue:))
            let directory = value("capture-directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.appState.captureFullscreen(action: action, preferredDirectory: directory)
            }
            if let resultPath = value("result") {
                writeRuntimeResult(
                    to: resultPath,
                    after: 1,
                    baselineRecordIDs: baselineRecordIDs,
                    // Without an explicit action, AppState applies the after-capture preferences.
                    waitsForUpload: action.map { $0 == .upload } ?? appState.preferences.afterCaptureActions.contains(.upload)
                )
            }
        }

        if let path = value("editor-snapshot") {
            DispatchQueue.main.async { [weak self] in
                guard let self, let icon = NSApplication.shared.applicationIconImage else { return }
                NSApp.setActivationPolicy(.regular)
                appState.openEditor(image: icon)
                snapshotWindow(titled: "Annotate", to: path)
            }
        }

        if let path = value("history-snapshot") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSApp.setActivationPolicy(.regular)
                appState.openHistory()
                snapshotWindow(titled: "Capture History", to: path)
            }
        }

        if let path = value("quick-access-snapshot") {
            DispatchQueue.main.async { [weak self] in
                guard let self, let icon = NSApplication.shared.applicationIconImage else { return }
                let record = CaptureRecord(
                    id: UUID(), kind: .imported, createdAt: Date(),
                    fileURL: URL(fileURLWithPath: "/tmp/Screenshot Preview.png"),
                    projectURL: nil, thumbnailURL: nil,
                    width: Int(icon.size.width), height: Int(icon.size.height),
                    sourceApplication: "Screenshot", sourceWindow: "Preview",
                    cloudShareURL: nil, cloudID: nil, tags: [], isFavorite: false
                )
                appState.quickAccessController?.show(record: record, image: icon)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let panel = NSApp.windows.first(where: { $0 is NSPanel }) else { return }
                    self?.saveWindowSnapshot(panel, to: URL(fileURLWithPath: path))
                }
            }
        }

        if let recordingArgument = arguments.first(where: {
            $0.hasPrefix("--record-fullscreen=") || $0.hasPrefix("--record-gif=")
        }),
           let rawDuration = recordingArgument.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init),
           let duration = TimeInterval(rawDuration), duration > 0 {
            appState.presentsErrors = false
            appState.lastError = nil
            let baselineRecordIDs = Set(appState.history.records.map(\.id))
            let format: RecordingFormat = recordingArgument.hasPrefix("--record-gif=") ? .gif : .mp4
            let directory = value("recording-directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.appState.recordFullscreen(duration: duration, preferredDirectory: directory, format: format)
            }
            if let resultPath = value("result") {
                writeRuntimeResult(to: resultPath, after: duration + 1, baselineRecordIDs: baselineRecordIDs)
            }
        }
    }

    /// `waitsForUpload` keeps polling until the new record has a share URL or an error is
    /// reported, so an upload automation never reports success before the upload finishes.
    private func writeRuntimeResult(
        to path: String,
        after delay: TimeInterval,
        baselineRecordIDs: Set<UUID>,
        waitsForUpload: Bool = false
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pollRuntimeResult(
                to: path,
                baselineRecordIDs: baselineRecordIDs,
                waitsForUpload: waitsForUpload,
                // 0.5 s per attempt: 60 s for a capture, 200 s to cover the 180 s upload timeout.
                attemptsRemaining: waitsForUpload ? 400 : 120
            )
        }
    }

    private func pollRuntimeResult(
        to path: String,
        baselineRecordIDs: Set<UUID>,
        waitsForUpload: Bool,
        attemptsRemaining: Int
    ) {
        let record = appState.history.records.first { !baselineRecordIDs.contains($0.id) }
        let complete = record != nil && (!waitsForUpload || record?.cloudShareURL != nil)
        // A non-upload error (such as a history warning) must not end the wait while the upload
        // is still running; AppState sets progress to 0 at start, 1 on success, nil on failure.
        let uploadInFlight = waitsForUpload && record != nil && !complete && appState.uploadProgress == 0
        if !complete, appState.lastError == nil || uploadInFlight, attemptsRemaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pollRuntimeResult(
                    to: path,
                    baselineRecordIDs: baselineRecordIDs,
                    waitsForUpload: waitsForUpload,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        var errorMessage = appState.lastError
        if errorMessage == nil, !complete {
            errorMessage = record == nil ? "Timed out waiting for the capture." : "Timed out waiting for the upload."
        }
        let payload: [String: Any] = [
            "ok": complete && appState.lastError == nil,
            "error": errorMessage ?? NSNull(),
            "recording": appState.isRecording,
            "record": record.map { record in
                [
                    "id": record.id.uuidString,
                    "kind": record.kind.rawValue,
                    "file": record.fileURL.path,
                    "cloudURL": record.cloudShareURL?.absoluteString ?? NSNull(),
                    "width": record.width,
                    "height": record.height,
                ] as [String: Any]
            } ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func snapshotWindow(titled title: String, to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let window = NSApp.windows.first(where: { $0.title == title }) else { return }
            self?.saveWindowSnapshot(window, to: URL(fileURLWithPath: path))
        }
    }

    private func saveWindowSnapshot(_ window: NSWindow, to url: URL) {
        typealias WindowSnapshotFunction = @convention(c) (
            CGRect, UInt32, CGWindowID, UInt32
        ) -> Unmanaged<CGImage>?

        window.displayIfNeeded()
        guard let framework = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ) else { return }
        defer { dlclose(framework) }
        guard let symbol = dlsym(framework, "CGWindowListCreateImage") else { return }
        let snapshot = unsafeBitCast(symbol, to: WindowSnapshotFunction.self)
        guard let cgImage = snapshot(
            .null,
            CGWindowListOption.optionIncludingWindow.rawValue,
            CGWindowID(window.windowNumber),
            CGWindowImageOption.boundsIgnoreFraming.rawValue
        )?.takeRetainedValue() else { return }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    private func handleActionURL(_ url: URL) {
        guard url.scheme?.lowercased() == "subset-screenshot" else { return }
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch action {
        // Any web page or app can open these URLs, so URL-triggered captures never run the
        // Upload after-capture action; the user can still upload from Quick Access or History.
        case "all-in-one", "capture-area": appState.captureArea(allowsUpload: false)
        case "capture-window": appState.captureWindow(allowsUpload: false)
        case "capture-fullscreen": appState.captureFullscreen(allowsUpload: false)
        case "capture-previous-area": appState.capturePreviousArea(allowsUpload: false)
        case "scrolling-capture": appState.captureScrolling(allowsUpload: false)
        case "record-screen": appState.startRecording()
        case "record-gif": appState.startRecording(format: .gif)
        case "capture-text": appState.captureText()
        case "history": appState.openHistory()
        case "settings":
            let tab = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "tab" })?.value
                .flatMap(SettingsTab.init(rawValue:)) ?? .general
            showSettings(tab: tab)
        default: break
        }
    }
}
