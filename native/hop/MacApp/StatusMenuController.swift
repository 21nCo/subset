import AppKit
import HopCore

/// The menu bar item and its menu, built from `ShellCommand` so the menu and its tests share one list. While Hop
/// lacks the Accessibility permission, the item shows a warning symbol and the menu starts with a way to allow it.
@MainActor
final class StatusMenuController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let perform: (ShellCommand) -> Void

    init(perform: @escaping (ShellCommand) -> Void, ready: Bool) {
        self.perform = perform
        item.menu = menu
        update(ready: ready)
    }

    /// Shows the normal state when the shortcut is running, or the needs-permission state when it is not.
    func update(ready: Bool) {
        let label = ready ? HopIdentity.appName : "\(HopIdentity.appName): needs Accessibility access"
        let symbol = ready ? "macwindow.on.rectangle" : "exclamationmark.triangle"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            image.isTemplate = true
            item.button?.image = image
            item.button?.title = ""
        } else {
            item.button?.image = nil
            item.button?.title = ready ? HopIdentity.appName : "\(HopIdentity.appName) !"
        }
        item.button?.setAccessibilityLabel(label)
        item.button?.toolTip = label
        menu.removeAllItems()
        for command in ShellCommand.statusMenu(trusted: ready) {
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
