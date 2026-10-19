import AppKit
import SystemCore

/// The menu bar item and its menu, built from `ShellCommand` so the menu and its tests share one list. The item
/// shows the machine's CPU use as its title and memory pressure as its symbol; the menu repeats both as text.
@MainActor
final class StatusMenuController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let cpuRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pressureRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(perform: @escaping (ShellCommand) -> Void) {
        item.button?.imagePosition = .imageLeading
        for row in [cpuRow, pressureRow] {
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())
        for command in ShellCommand.allCases {
            if command.startsGroup { menu.addItem(.separator()) }
            menu.addItem(CommandMenuItem(command: command, perform: perform))
        }
        item.menu = menu
    }

    func update(_ summary: StatusSummary, logicalCoreCount: Int?) {
        guard let button = item.button else { return }
        button.image = Self.image(for: summary.pressure)
        button.title = summary.title
        button.setAccessibilityLabel(summary.accessibilityLabel)
        button.toolTip = summary.accessibilityLabel
        cpuRow.title = summary.cpuRow(logicalCoreCount: logicalCoreCount)
        pressureRow.title = summary.pressureRow
    }

    /// Normal (or unknown) pressure uses the template gauge; warning and critical use a colored memory chip so the
    /// change shows without reading the menu.
    private static func image(for pressure: MemoryPressure?) -> NSImage? {
        let label = "Memory pressure \(pressure?.title.lowercased() ?? "unknown")"
        switch pressure {
        case .warning, .critical:
            let color: NSColor = pressure == .critical ? .systemRed : .systemYellow
            let image = NSImage(systemSymbolName: "memorychip.fill", accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
            image?.isTemplate = false
            return image
        case .normal, nil:
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: label)
            image?.isTemplate = true
            return image
        }
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
