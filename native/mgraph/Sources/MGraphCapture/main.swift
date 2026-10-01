import AppKit
import CaptureCore
import Foundation

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
if arguments.count >= 2, arguments[arguments.count - 2] == "--invocation-id",
   UUID(uuidString: arguments.last!) != nil {
    arguments.removeLast(2)
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
        consent.informativeText = "M Graph Capture will read the current foreground app once and write its result to the command output."
        consent.addButton(withTitle: "Allow Capture")
        consent.addButton(withTitle: "Cancel")
        let timeout = ConsentTimeout(alert: consent)
        let timer = Timer.scheduledTimer(timeInterval: 5, target: timeout,
                                         selector: #selector(ConsentTimeout.expire), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .modalPanel)
        let approved = consent.runModal() == .alertFirstButtonReturn
        timer.invalidate()
        guard approved, let foreground else {
            printJSON(CaptureResult(state: .readFailed, error: "Command capture was not approved"))
            exit(2)
        }
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
        private var captureItem: NSMenuItem!
        private var captureDeadline: CaptureCollector.Deadline?
        private let captureRequests = CaptureRequestGate()

        func applicationDidFinishLaunching(_ _: Notification) {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "M Graph"
            let menu = NSMenu()
            statusItem = NSMenuItem(title: "Checking Accessibility…", action: nil, keyEquivalent: "")
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem(title: "Request Accessibility Access", action: #selector(request), keyEquivalent: ""))
            captureItem = NSMenuItem(title: "Capture Foreground", action: #selector(capture), keyEquivalent: "")
            menu.addItem(captureItem)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit M Graph", action: #selector(quit), keyEquivalent: "q"))
            for entry in menu.items { entry.target = self }
            item.menu = menu
            refresh()
            Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        }

        @objc private func refresh() {
            statusItem.title = CaptureCollector.isTrusted() ? "Accessibility: Granted" : "Accessibility: Required"
        }

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

        @objc private func capture() {
            guard captureItem.isEnabled else { return }
            let token = captureRequests.begin()
            captureItem.isEnabled = false
            statusItem.title = "Capturing foreground…"
            captureDeadline = CaptureCollector.captureForeground { [weak self] result in
                guard let self, self.captureRequests.finish(token) else { return }
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

        @objc private func quit() {
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
