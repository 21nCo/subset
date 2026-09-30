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
        let result = CaptureCollector.captureForeground()
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

        func applicationDidFinishLaunching(_ notification: Notification) {
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
            captureDeadline?.cancel()
            CaptureCollector.requestAccess()
            refresh()
        }

        @objc private func capture() {
            captureItem.isEnabled = false
            statusItem.title = "Capturing foreground…"
            captureDeadline = CaptureCollector.captureForeground { [weak self] result in
                guard let self else { return }
                self.captureDeadline = nil
                self.captureItem.isEnabled = true
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
