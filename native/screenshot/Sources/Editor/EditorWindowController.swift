import AppKit
import SwiftUI

@MainActor
final class EditorWindowController {
    private let appState: AppState
    private var controllers: [ObjectIdentifier: (controller: NSWindowController, observer: NSObjectProtocol)] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    func show(image: NSImage, record: CaptureRecord?) {
        let session = EditorSession(image: image, record: record)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar], backing: .buffered, defer: false)
        window.title = record?.displayName ?? "Annotate"
        window.center()
        window.minSize = CGSize(width: 760, height: 520)
        window.contentView = NSHostingView(rootView: EditorView(session: session, appState: appState))
        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Release the session (image plus undo snapshots) when its window closes.
        let key = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let entry = self.controllers.removeValue(forKey: key) else { return }
                NotificationCenter.default.removeObserver(entry.observer)
            }
        }
        controllers[key] = (controller, observer)
    }
}
