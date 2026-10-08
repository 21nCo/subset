import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var onOpenBottom: (() -> Void)?
    private var onOpenSide: (() -> Void)?
    private var onToggleCapture: (() -> Void)?
    private var onClearHistory: (() -> Void)?
    private var onEnablePaste: (() -> Void)?
    private var onQuit: (() -> Void)?

    override init() {
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard.fill",
                accessibilityDescription: "Clipboard"
            )
            button.imagePosition = .imageOnly
            button.toolTip = "Clipboard"
        }
    }

    func configure(
        onOpenBottom: @escaping () -> Void,
        onOpenSide: @escaping () -> Void,
        onToggleCapture: @escaping () -> Void,
        onClearHistory: @escaping () -> Void,
        onEnablePaste: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenBottom = onOpenBottom
        self.onOpenSide = onOpenSide
        self.onToggleCapture = onToggleCapture
        self.onClearHistory = onClearHistory
        self.onEnablePaste = onEnablePaste
        self.onQuit = onQuit
        refresh(itemCount: 0, isCapturePaused: false, statusMessage: "Clipboard monitor ready.", canPasteDirectly: true)
    }

    func refresh(itemCount: Int, isCapturePaused: Bool, statusMessage: String, canPasteDirectly: Bool) {
        let menu = NSMenu()

        // Key equivalents mirror the global shortcuts so they are discoverable from the menu bar.
        let openItem = NSMenuItem(
            title: "Open Bottom Shelf",
            action: #selector(handleOpenBottom),
            keyEquivalent: "v"
        )
        openItem.keyEquivalentModifierMask = [.command, .shift]
        openItem.target = self
        menu.addItem(openItem)

        let openSideItem = NSMenuItem(
            title: "Open Right Shelf",
            action: #selector(handleOpenSide),
            keyEquivalent: "v"
        )
        openSideItem.keyEquivalentModifierMask = [.command, .option, .shift]
        openSideItem.target = self
        menu.addItem(openSideItem)

        if !canPasteDirectly {
            let enableItem = NSMenuItem(
                title: "Enable Direct Paste…",
                action: #selector(handleEnablePaste),
                keyEquivalent: ""
            )
            enableItem.toolTip = "Grant Accessibility so a chosen item is pasted into the previous app. Without it, items are copied to the clipboard for a manual ⌘V."
            enableItem.target = self
            menu.addItem(enableItem)
        }

        menu.addItem(.separator())

        let pauseItem = NSMenuItem(
            title: isCapturePaused ? "Resume Capture" : "Pause Capture",
            action: #selector(handleToggleCapture),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let clearItem = NSMenuItem(
            title: itemCount == 0 ? "Clear History…" : "Clear History (\(itemCount))…",
            action: #selector(handleClearHistory),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = itemCount > 0
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let statusItem = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Clipboard", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    @objc
    private func handleOpenBottom() {
        onOpenBottom?()
    }

    @objc
    private func handleOpenSide() {
        onOpenSide?()
    }

    @objc
    private func handleToggleCapture() {
        onToggleCapture?()
    }

    @objc
    private func handleClearHistory() {
        onClearHistory?()
    }

    @objc
    private func handleEnablePaste() {
        onEnablePaste?()
    }

    @objc
    private func handleQuit() {
        onQuit?()
    }
}
