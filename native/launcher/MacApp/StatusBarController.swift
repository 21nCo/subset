import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var onOpenLauncher: (() -> Void)?
    private var onNewQuickNote: (() -> Void)?
    private var onOpenQuickNotes: (() -> Void)?
    private var isAvatarVisible: (() -> Bool)?
    private weak var avatarItem: NSMenuItem?
    private var onToggleAvatar: (() -> Void)?
    private var onQuit: (() -> Void)?
    private var isLauncherHotkeyAvailable = true
    private var isQuickNoteHotkeyAvailable = true

    override init() {
        super.init()

        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Launcher (⌥Space)"
            button.setAccessibilityLabel("Launcher")
        }
    }

    private static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: 17, weight: .heavy),
                toHaveTrait: .italicFontMask
            ),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        NSString(string: "S").draw(
            in: NSRect(x: 0, y: 0.5, width: size.width, height: size.height),
            withAttributes: attributes
        )

        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = "Launcher"
        return image
    }

    func configure(
        onOpenLauncher: @escaping () -> Void,
        onNewQuickNote: @escaping () -> Void,
        onOpenQuickNotes: @escaping () -> Void,
        isAvatarVisible: @escaping () -> Bool,
        onToggleAvatar: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        isLauncherHotkeyAvailable: Bool = true,
        isQuickNoteHotkeyAvailable: Bool = true
    ) {
        self.isLauncherHotkeyAvailable = isLauncherHotkeyAvailable
        self.isQuickNoteHotkeyAvailable = isQuickNoteHotkeyAvailable
        if !isLauncherHotkeyAvailable, let button = statusItem.button {
            button.toolTip = "Launcher (⌥Space is used by another app)"
        }
        self.onOpenLauncher = onOpenLauncher
        self.onNewQuickNote = onNewQuickNote
        self.onOpenQuickNotes = onOpenQuickNotes
        self.isAvatarVisible = isAvatarVisible
        self.onToggleAvatar = onToggleAvatar
        self.onQuit = onQuit
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        avatarItem?.state = (isAvatarVisible?() ?? false) ? .on : .off
    }

    private func refresh() {
        let menu = NSMenu()
        menu.delegate = self

        // Key equivalents mirror the global shortcuts so they are discoverable here.
        // A shortcut that could not be registered is not advertised.
        menu.addItem(isLauncherHotkeyAvailable
            ? item("Open Launcher", #selector(handleOpenLauncher), key: " ", modifiers: [.option])
            : item("Open Launcher (⌥Space unavailable)", #selector(handleOpenLauncher)))
        menu.addItem(isQuickNoteHotkeyAvailable
            ? item("New Quick Note", #selector(handleNewQuickNote), key: "n", modifiers: [.control, .option])
            : item("New Quick Note (⌃⌥N unavailable)", #selector(handleNewQuickNote)))
        menu.addItem(item("Quick Notes…", #selector(handleOpenQuickNotes)))

        menu.addItem(.separator())

        let avatarItem = item("Show Floating Button", #selector(handleToggleAvatar))
        avatarItem.toolTip = "A small always-on-top button that opens Launcher when clicked. Drag it to move it."
        self.avatarItem = avatarItem
        menu.addItem(avatarItem)

        menu.addItem(.separator())
        menu.addItem(item("Quit Launcher", #selector(handleQuit), key: "q", modifiers: [.command]))

        statusItem.menu = menu
    }

    private func item(
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func handleNewQuickNote() {
        onNewQuickNote?()
    }

    @objc private func handleOpenQuickNotes() {
        onOpenQuickNotes?()
    }

    @objc private func handleOpenLauncher() {
        onOpenLauncher?()
    }

    @objc private func handleToggleAvatar() {
        onToggleAvatar?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }
}
