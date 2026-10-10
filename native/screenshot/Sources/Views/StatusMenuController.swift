import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder.circle.fill", accessibilityDescription: "Screenshot")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Screenshot"
        menu.delegate = self
        statusItem.menu = menu
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        menu.addItem(header("Screenshot"))
        menu.addItem(action("All-In-One", symbol: "sparkles", key: "a") { [weak self] in self?.appState.captureArea() })
        menu.addItem(.separator())
        menu.addItem(action("Capture Area", symbol: "viewfinder", key: "s", modifiers: [.control, .option]) { [weak self] in self?.appState.captureArea() })
        menu.addItem(action("Capture Window", symbol: "macwindow", key: "s", modifiers: [.control, .option, .shift]) { [weak self] in self?.appState.captureWindow() })
        menu.addItem(action("Capture Fullscreen", symbol: "rectangle.inset.filled", key: "f") { [weak self] in self?.appState.captureFullscreen() })
        menu.addItem(action("Capture Previous Area", symbol: "arrow.counterclockwise", key: "p") { [weak self] in self?.appState.capturePreviousArea() })
        menu.addItem(action("Scrolling Capture", symbol: "arrow.down.to.line.compact", key: "s") { [weak self] in self?.appState.captureScrolling() })
        menu.addItem(action("Self-Timer", symbol: "timer", key: "t") { [weak self] in self?.appState.captureWithTimer() })
        menu.addItem(.separator())
        menu.addItem(action(appState.isRecording ? "Stop Recording" : "Record Screen", symbol: appState.isRecording ? "stop.circle.fill" : "record.circle", key: "r", modifiers: [.control, .option, .shift]) { [weak self] in
            guard let self else { return }
            appState.isRecording ? appState.stopRecording() : appState.startRecording()
        })
        menu.addItem(action("Record GIF", symbol: "rectangle.stack.badge.play", key: "g") { [weak self] in self?.appState.startRecording(format: .gif) })
        menu.addItem(action("Capture Text", symbol: "text.viewfinder", key: "o", modifiers: [.control, .option, .shift]) { [weak self] in self?.appState.captureText() })
        menu.addItem(.separator())
        menu.addItem(action("Open Annotate…", symbol: "pencil.and.outline", key: "e") { [weak self] in self?.openFileInEditor() })
        menu.addItem(action("Pin Image…", symbol: "pin", key: "i") { [weak self] in self?.pinFile() })
        menu.addItem(action("Capture History…", symbol: "clock.arrow.circlepath", key: "h", modifiers: [.control, .option, .shift]) { [weak self] in self?.appState.openHistory() })
        menu.addItem(action("Restore Last Capture", symbol: "arrow.uturn.backward", key: "z") { [weak self] in self?.appState.restoreMostRecent() })
        menu.addItem(.separator())
        menu.addItem(action("Settings…", symbol: "gearshape", key: ",") { [weak self] in self?.appState.showSettings() })
        menu.addItem(action("Quit Screenshot", symbol: "power", key: "q") { NSApp.terminate(nil) })
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        item.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        return item
    }

    private func action(
        _ title: String,
        symbol: String,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.invoke), keyEquivalent: key, handler: handler)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.image?.isTemplate = true
        return item
    }

    private func openFileInEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        appState.openEditor(image: image)
    }

    private func pinFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        appState.pinController?.pin(image: image, title: url.deletingPathExtension().lastPathComponent)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: Selector?, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: action, keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func invoke() { handler() }
}
