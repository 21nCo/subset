import AppKit
import SwiftUI

@MainActor
final class EditorWindowController {
    private let appState: AppState
    private var controllers: [NSWindowController] = []

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
        controllers.append(controller)
        controllers.removeAll { $0.window == nil }
    }
}
