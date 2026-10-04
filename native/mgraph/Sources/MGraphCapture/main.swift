import AppKit
import CaptureCore
import Foundation

/// Emits one structured CLI result without changing recording state.
private func printJSON(_ result: CaptureResult) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(result), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

@MainActor private final class ConsentTimeout: NSObject {
    let alert: NSAlert
    init(alert: NSAlert) { self.alert = alert }
    @objc func expire() {
        NSApplication.shared.abortModal()
        alert.window.orderOut(nil)
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
// LaunchServices checks tag only their own process so a timeout cannot kill an
// unrelated, preexisting M Graph instance.
var checkInvocation: UUID?
var checkRecordingDirectory: URL?
if arguments.count >= 6, arguments[arguments.count - 6] == "--shutdown-after",
   let lifetime = Int(arguments[arguments.count - 5]), (1...120).contains(lifetime),
   arguments[arguments.count - 4] == "--shutdown-file",
   arguments[arguments.count - 2] == "--invocation-id",
   let invocation = UUID(uuidString: arguments.last!) {
    let shutdown = URL(fileURLWithPath: arguments[arguments.count - 3])
    let ready = shutdown.deletingLastPathComponent().appendingPathComponent("ready")
    checkRecordingDirectory = shutdown.deletingLastPathComponent().appendingPathComponent("recording", isDirectory: true)
    let deferReady = arguments.count == 7 && arguments[0] == "--defer-ready"
    if deferReady {
        let control = shutdown.deletingLastPathComponent()
        let starting = control.appendingPathComponent("starting")
        let release = control.appendingPathComponent("release-ready")
        do {
            try String(getpid()).write(to: starting, atomically: true, encoding: .utf8)
        } catch {
            fputs("M Graph check could not publish startup identity\n", stderr)
            exit(3)
        }
        let deadline = DispatchTime.now() + .seconds(5)
        while DispatchTime.now() < deadline {
            if (try? String(contentsOf: release, encoding: .utf8)) == invocation.uuidString {
                break
            }
            if (try? String(contentsOf: shutdown, encoding: .utf8)) == invocation.uuidString {
                exit(0)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard (try? String(contentsOf: release, encoding: .utf8)) == invocation.uuidString else {
            fputs("M Graph check readiness release timed out\n", stderr)
            exit(3)
        }
    }
    do {
        try String(getpid()).write(to: ready, atomically: true, encoding: .utf8)
    } catch {
        fputs("M Graph check could not establish its invocation identity\n", stderr)
        exit(3)
    }
    checkInvocation = invocation
    DispatchQueue.global(qos: .utility).async {
        let expiry = DispatchTime.now() + .seconds(lifetime)
        while DispatchTime.now() < expiry {
            if (try? String(contentsOf: shutdown, encoding: .utf8)) == invocation.uuidString {
                exit(0)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        exit(0)
    }
    arguments.removeLast(6)
    if deferReady { arguments.removeAll() }
}
var expectedFixtureTitle: String?
if checkInvocation != nil, arguments.count == 2, arguments[0] == "--expected-fixture-title",
   arguments[1].range(of: "^MGraph Menu Fixture [a-f0-9]{8}\\.txt$", options: .regularExpression) != nil {
    expectedFixtureTitle = arguments[1]
    arguments.removeAll()
}
if let command = arguments.first {
    guard arguments.count == 1 else {
        fputs("Usage: MGraphCapture [status|request-access|capture]\n", stderr)
        exit(64)
    }
    switch command {
    case "status":
        printJSON(CaptureCollector.status())
    case "request-access":
        CaptureCollector.requestAccess()
        printJSON(CaptureCollector.status())
    case "capture":
        // A TCC grant applies to the whole signed app, including CLI launches.
        // Require a fresh local confirmation so another process cannot silently
        // launch the granted executable to read foreground text.
        guard CaptureCollector.isTrusted() else {
            printJSON(CaptureCollector.status())
            exit(2)
        }
        let foreground = NSWorkspace.shared.frontmostApplication
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        let consent = NSAlert()
        consent.messageText = "Allow foreground capture?"
        consent.informativeText = "M Graph Capture will read the current foreground app once and write its result to the command output." +
            (checkInvocation.map { " Check \($0.uuidString)." } ?? "")
        consent.addButton(withTitle: "Allow Capture")
        consent.addButton(withTitle: "Cancel")
        let timeout = ConsentTimeout(alert: consent)
        let timer = Timer.scheduledTimer(timeInterval: 5, target: timeout,
                                         selector: #selector(ConsentTimeout.expire), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .modalPanel)
        let approved = consent.runModal() == .alertFirstButtonReturn
        timer.invalidate()
        if let failure = CaptureCollector.cliConsentFailure(approved: approved,
                                                            foregroundAvailable: foreground != nil) {
            printJSON(failure)
            exit(2)
        }
        guard let foreground else { fatalError("Validated foreground application disappeared") }
        foreground.activate()
        Thread.sleep(forTimeInterval: 0.15)
        let result = CaptureCollector.captureForeground(expectedProcessIdentifier: foreground.processIdentifier)
        printJSON(result)
        if result.state != .available { exit(2) }
    default:
        fputs("Usage: MGraphCapture [status|request-access|capture]\n", stderr)
        exit(64)
    }
} else {
    @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
        private var item: NSStatusItem!
        private var statusItem: NSMenuItem!
        private var recordingItem: NSMenuItem!
        private var countItem: NSMenuItem!
        private var recordingErrorItem: NSMenuItem!
        private var allowedMenu: NSMenu!
        private var captureItem: NSMenuItem!
        private var captureDeadline: CaptureCollector.Deadline?
        private let captureRequests = CaptureRequestGate()
        private var recording: RecordingController?
        private var recordingError: String?
        private var recordingDirectory: URL!
        private var shownAppEntries: [String] = []

        /// Starts the locked recorder and exposes explicit menu controls in Off mode.
        func applicationDidFinishLaunching(_ _: Notification) {
            recordingDirectory = checkRecordingDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                                      in: .userDomainMask)[0]
                .appendingPathComponent("MGraphCapture", isDirectory: true)
            openRecording()
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = checkInvocation.map { "M Graph · \($0.uuidString)" } ?? "M Graph"
            let menu = NSMenu()
            statusItem = NSMenuItem(title: "Checking Accessibility…", action: nil, keyEquivalent: "")
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem(title: "Request Accessibility Access", action: #selector(request), keyEquivalent: ""))
            recordingItem = NSMenuItem(title: "Recording: Off", action: nil, keyEquivalent: "")
            menu.addItem(recordingItem)
            countItem = NSMenuItem(title: "Captured observations: 0", action: nil, keyEquivalent: "")
            menu.addItem(countItem)
            recordingErrorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            recordingErrorItem.isHidden = true
            menu.addItem(recordingErrorItem)
            menu.addItem(NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Pause Recording", action: #selector(pauseRecording), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Allow App…", action: #selector(allowApp), keyEquivalent: ""))
            let allowedItem = NSMenuItem(title: "Allowed Apps and Captured Data", action: nil, keyEquivalent: "")
            allowedMenu = NSMenu()
            allowedItem.submenu = allowedMenu
            menu.addItem(allowedItem)
            menu.addItem(NSMenuItem(title: "Show Last Capture", action: #selector(showLastCapture), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Delete Captured Data…", action: #selector(deleteData), keyEquivalent: ""))
            menu.addItem(.separator())
            captureItem = NSMenuItem(title: "Capture Foreground", action: #selector(capture), keyEquivalent: "")
            menu.addItem(captureItem)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit M Graph", action: #selector(quit), keyEquivalent: "q"))
            for entry in menu.items { entry.target = self }
            item.menu = menu
            refresh()
            Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        }

        /// Opens one vault owner or records why automatic capture is unavailable.
        private func openRecording() {
            do {
                recording = try RecordingController(vault: RecordingVault(directory: recordingDirectory))
                recordingError = nil
            } catch {
                recording = nil
                recordingError = error.localizedDescription
            }
        }

        /// Reflects current trust, recording mode, retained count, and allowed app actions.
        @objc private func refresh() {
            statusItem.title = CaptureCollector.isTrusted() ? "Accessibility: Granted" : "Accessibility: Required"
            if let recording {
                recordingItem.title = "Recording: \(recording.vault.settings.mode.rawValue.capitalized)"
                countItem.title = "Captured observations: \(recording.vault.observations.count)"
                let error = recording.lastError ?? recording.observerError
                recordingErrorItem.title = error.map { "Recording error: \($0)" } ?? ""
                recordingErrorItem.isHidden = error == nil
                let allowedApps = recording.vault.settings.allowedApps.keys.sorted()
                let retainedApps = recording.vault.retainedAppIdentifiers
                let appEntries = allowedApps.map { "allowed:\($0)" } + retainedApps.map { "retained:\($0)" }
                if shownAppEntries != appEntries || allowedMenu.items.isEmpty {
                    shownAppEntries = appEntries
                    allowedMenu.removeAllItems()
                    for bundleID in Set(allowedApps + retainedApps).sorted() {
                        if allowedApps.contains(bundleID) {
                            let exclude = NSMenuItem(title: "Exclude \(bundleID)", action: #selector(excludeApp(_:)), keyEquivalent: "")
                            exclude.representedObject = bundleID
                            exclude.target = self
                            allowedMenu.addItem(exclude)
                        }
                        if retainedApps.contains(bundleID) {
                            let erase = NSMenuItem(title: "Delete Data: \(bundleID)", action: #selector(deleteAppData(_:)), keyEquivalent: "")
                            erase.representedObject = bundleID
                            erase.target = self
                            allowedMenu.addItem(erase)
                        }
                    }
                    if allowedMenu.items.isEmpty {
                        allowedMenu.addItem(NSMenuItem(title: "No allowed apps or captured data", action: nil, keyEquivalent: ""))
                    }
                }
            } else {
                recordingItem.title = "Recording: Unavailable"
                countItem.title = "Captured observations: unavailable"
                recordingErrorItem.title = recordingError ?? "Recording settings unavailable"
                recordingErrorItem.isHidden = false
            }
        }

        /// Persists a user-selected mode and surfaces storage failures in the menu.
        private func changeMode(_ mode: RecordingMode) {
            guard let recording else { showRecordingUnavailable(); return }
            do { try recording.setMode(mode) }
            catch { showError(error) }
            refresh()
        }

        @objc private func startRecording() { changeMode(.recording) }
        @objc private func pauseRecording() { changeMode(.paused) }
        @objc private func stopRecording() { changeMode(.off) }

        /// Grants recording only to the bundle selected through the local app picker.
        @objc private func allowApp() {
            guard let recording else { showRecordingUnavailable(); return }
            let panel = NSOpenPanel()
            panel.message = "Choose an application to allow for foreground recording"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard url.pathExtension.lowercased() == "app", let bundleID = Bundle(url: url)?.bundleIdentifier else {
                showError(RecordingError.invalidBundleIdentifier(url.lastPathComponent))
                return
            }
            do { try recording.allow(bundleID, at: url) }
            catch { showError(error) }
            refresh()
        }

        /// Removes a selected app from the allowlist while retaining old data for deletion.
        @objc private func excludeApp(_ sender: NSMenuItem) {
            guard let bundleID = sender.representedObject as? String else { return }
            guard let recording else { showRecordingUnavailable(); return }
            do { try recording.exclude(bundleID) }
            catch { showError(error) }
            refresh()
        }

        /// Confirms and erases one app's retained observations.
        @objc private func deleteAppData(_ sender: NSMenuItem) {
            guard let bundleID = sender.representedObject as? String,
                  confirmDeletion("Delete all captured data for \(bundleID)?") else { return }
            guard let recording else { showRecordingUnavailable(); return }
            do { try recording.deleteCapturedData(bundleIdentifier: bundleID) }
            catch { showError(error) }
            refresh()
        }

        /// Erases every archived observation, including recovery from a damaged archive.
        @objc private func deleteData() {
            guard confirmDeletion("Delete all captured observations?") else { return }
            do {
                if let recording {
                    try recording.deleteCapturedData()
                } else {
                    try RecordingVault.eraseArchiveWhileClosed(in: recordingDirectory)
                    openRecording()
                }
            }
            catch { showError(error) }
            refresh()
        }

        /// Requires a local confirmation before captured text is removed.
        private func confirmDeletion(_ message: String) -> Bool {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = "This removes the local captured text and cannot be undone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        /// Displays the most recent retained result locally without exporting it.
        @objc private func showLastCapture() {
            guard let result = recording?.vault.observations.last else { return }
            let alert = NSAlert()
            alert.messageText = result.applicationName ?? result.bundleIdentifier ?? "Last capture"
            alert.informativeText = [result.observedAt.formatted(), result.windowTitle, result.text]
                .compactMap { $0 }.joined(separator: "\n\n")
            alert.addButton(withTitle: "Close")
            alert.runModal()
        }

        private func showError(_ error: Error) {
            let alert = NSAlert()
            alert.messageText = "Recording operation failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }

        private func showRecordingUnavailable() {
            let alert = NSAlert()
            alert.messageText = "Recording unavailable"
            alert.informativeText = recordingError ?? "Recording settings could not be opened."
            alert.runModal()
        }

        /// Cancels a one-shot read before requesting the operating system AX grant.
        @objc private func request() {
            captureRequests.cancel()
            captureDeadline?.cancel()
            captureDeadline = nil
            captureItem.isEnabled = false
            CaptureCollector.afterCaptureWorkerDrains { [weak self] in
                self?.captureItem.isEnabled = true
            }
            CaptureCollector.requestAccess()
            refresh()
        }

        /// Runs a separate manual diagnostic read and fences stale menu results.
        @objc private func capture() {
            guard captureItem.isEnabled else { return }
            let token = captureRequests.begin()
            captureItem.isEnabled = false
            statusItem.title = "Capturing foreground…"
            captureDeadline = CaptureCollector.captureForeground { [weak self] captured in
                guard let self, self.captureRequests.finish(token) else { return }
                let result = expectedFixtureTitle.map {
                    CaptureCollector.bindFixture(captured, bundleIdentifier: "com.apple.TextEdit", windowTitle: $0)
                } ?? captured
                self.captureDeadline = nil
                CaptureCollector.afterCaptureWorkerDrains { [weak self] in
                    self?.captureItem.isEnabled = true
                }
                NSApplication.shared.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = result.applicationName.map { "\($0) — \(result.state.rawValue)" } ?? result.state.rawValue
                alert.informativeText = [result.windowTitle, result.documentURL, result.text, result.error]
                    .compactMap { $0 }.joined(separator: "\n\n")
                alert.addButton(withTitle: "OK")
                alert.runModal()
                self.refresh()
            }
        }

        /// Stops the recorder and cancels pending diagnostic capture on exit.
        @objc private func quit() {
            recording?.stop()
            captureRequests.cancel()
            captureDeadline?.cancel()
            NSApplication.shared.terminate(nil)
        }
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
