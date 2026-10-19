import AppKit
import SystemCore

/// The menu bar item and its menu, built from `ShellCommand` so the menu and its tests share one list.
@MainActor
final class StatusMenuController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(perform: @escaping (ShellCommand) -> Void) {
        let label = SystemIdentity.appName
        if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: label) {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "System"
        }
        item.button?.setAccessibilityLabel(label)
        item.button?.toolTip = label
        for command in ShellCommand.allCases {
            if command.startsGroup { menu.addItem(.separator()) }
            menu.addItem(CommandMenuItem(command: command, perform: perform))
        }
        item.menu = menu
    }
}

/// A menu item that runs one shell command.
final class CommandMenuItem: NSMenuItem {
    private let command: ShellCommand
    private let perform: (ShellCommand) -> Void

    init(command: ShellCommand, title: String? = nil, perform: @escaping (ShellCommand) -> Void) {
        self.command = command
        self.perform = perform
        super.init(title: title ?? command.title, action: #selector(run), keyEquivalent: command.keyEquivalent)
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
        let appMenu = NSMenu(title: SystemIdentity.appName)
        appMenu.addItem(CommandMenuItem(command: .about, perform: perform))
        appMenu.addItem(.separator())
        appMenu.addItem(CommandMenuItem(command: .settings, perform: perform))
        appMenu.addItem(.separator())
        appMenu.addItem(CommandMenuItem(command: .quit, title: "Quit \(SystemIdentity.appName)", perform: perform))

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
