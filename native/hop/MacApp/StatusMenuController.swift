import AppKit
import HopCore

/// The menu bar item and its menu, built from `ShellCommand` so the menu and its tests share one list. While Hop
/// lacks the Accessibility permission, the item shows a warning symbol and the menu starts with a way to allow it.
@MainActor
final class StatusMenuController {
    enum State: Equatable {
        /// The shortcut is running.
        case ready
        /// Hop lacks the Accessibility permission.
        case needsPermission
        /// Hop has the permission but the system refused the event tap; the next sample retries it.
        case shortcutUnavailable
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let perform: (ShellCommand) -> Void
    private var state: State?

    init(perform: @escaping (ShellCommand) -> Void, state: State) {
        self.perform = perform
        item.menu = menu
        update(state: state)
    }

    /// Shows `state`. Does nothing when it is already shown, so a trust sample never rebuilds an open menu.
    func update(state: State) {
        guard state != self.state else { return }
        self.state = state
        let label = switch state {
        case .ready: HopIdentity.appName
        case .needsPermission: "\(HopIdentity.appName): needs Accessibility access"
        case .shortcutUnavailable: "\(HopIdentity.appName): shortcut unavailable"
        }
        let symbol = state == .ready ? "macwindow.on.rectangle" : "exclamationmark.triangle"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            image.isTemplate = true
            item.button?.image = image
            item.button?.title = ""
        } else {
            item.button?.image = nil
            item.button?.title = state == .ready ? HopIdentity.appName : "\(HopIdentity.appName) !"
        }
        item.button?.setAccessibilityLabel(label)
        item.button?.toolTip = label
        menu.removeAllItems()
        for command in ShellCommand.statusMenu(trusted: state != .needsPermission) {
            if command.startsGroup, menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(CommandMenuItem(command: command, perform: perform))
        }
    }
}

/// A menu item that runs one shell command.
final class CommandMenuItem: NSMenuItem {
    private let command: ShellCommand
    private let perform: (ShellCommand) -> Void

    init(command: ShellCommand, perform: @escaping (ShellCommand) -> Void) {
        self.command = command
        self.perform = perform
        super.init(title: command.title, action: #selector(run), keyEquivalent: command.keyEquivalent)
        target = self
    }

    required init(coder _: NSCoder) { fatalError("not used") }

    @objc private func run() { perform(command) }
}

/// The application menu. An accessory app shows no menu bar, but its key equivalents (⌘, ⌘Q ⌘W ⌘M) still work
/// while one of its windows is key.
@MainActor
enum MainMenu {
    static func make(perform: @escaping (ShellCommand) -> Void) -> NSMenu {
        let appMenu = NSMenu(title: HopIdentity.appName)
        appMenu.addItem(CommandMenuItem(command: .about, perform: perform))
        appMenu.addItem(.separator())
        appMenu.addItem(CommandMenuItem(command: .settings, perform: perform))
        appMenu.addItem(.separator())
        appMenu.addItem(CommandMenuItem(command: .quit, perform: perform))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let mainMenu = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return mainMenu
    }
}
