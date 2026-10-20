import AppKit
import SystemCore
import SystemProcesses

/// The menu bar item and its menu, built from `ShellCommand` so the menu and its tests share one list. The item
/// shows the machine's CPU use as its title and memory pressure as its symbol; the menu repeats both as text, then
/// lists the three largest App groups by memory, each opening the window on that group.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let cpuRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pressureRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let topGroupsTitle = NSMenuItem(title: "Largest by memory", action: nil, keyEquivalent: "")
    /// Standing rows, one per slot, updated in place so an open menu never loses the row under the pointer.
    private var topGroupRows: [NSMenuItem] = []
    private var topGroups = TopGroupsMenuState()
    private let openGroup: (OriginGroupID) -> Void

    init(perform: @escaping (ShellCommand) -> Void, openGroup: @escaping (OriginGroupID) -> Void) {
        self.openGroup = openGroup
        super.init()
        item.button?.imagePosition = .imageLeading
        for row in [cpuRow, pressureRow] {
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())
        topGroupsTitle.isEnabled = false
        menu.addItem(topGroupsTitle)
        topGroupRows = (0..<TopGroupsMenuState.slotCount).map { slot in
            // The row opens the group its slot shows when chosen, which stays put while the menu is open.
            let row = ActionMenuItem(title: "") { [weak self] in
                guard let self, let entry = topGroups.slots[slot] else { return }
                openGroup(entry.id)
            }
            row.indentationLevel = 1
            menu.addItem(row)
            return row
        }
        menu.addItem(.separator())
        for command in ShellCommand.allCases {
            if command.startsGroup { menu.addItem(.separator()) }
            menu.addItem(CommandMenuItem(command: command, perform: perform))
        }
        menu.delegate = self
        item.menu = menu
        showTopGroups()
    }

    func update(_ summary: StatusSummary, logicalCoreCount: Int?, topGroups: TopGroups) {
        if self.topGroups.receive(topGroups) { showTopGroups() }
        guard let button = item.button else { return }
        button.image = Self.image(for: summary)
        button.title = summary.title
        button.setAccessibilityLabel(summary.accessibilityLabel)
        button.toolTip = summary.accessibilityLabel
        cpuRow.title = summary.cpuRow(logicalCoreCount: logicalCoreCount)
        pressureRow.title = summary.pressureRow
    }

    func menuWillOpen(_: NSMenu) {
        if topGroups.menuWillOpen() { showTopGroups() }
    }

    func menuDidClose(_: NSMenu) {
        topGroups.menuDidClose()
    }

    /// Fills the standing rows from the shown groups and hides the unused ones. With none, the title says why.
    private func showTopGroups() {
        topGroupsTitle.title = topGroups.shown.placeholder ?? "Largest by memory"
        for (row, entry) in zip(topGroupRows, topGroups.slots) {
            row.isHidden = entry == nil
            row.title = entry?.title ?? ""
            row.setAccessibilityLabel(entry?.accessibilityLabel)
        }
    }

    /// The pressure symbol's needle position tells the levels apart; warning and critical are also colored so the
    /// change stands out without reading the menu.
    private static func image(for summary: StatusSummary) -> NSImage? {
        let label = "Memory pressure \(summary.pressureText.lowercased())"
        let image = NSImage(systemSymbolName: summary.pressureSymbolName, accessibilityDescription: label)
        switch summary.pressure {
        case .warning, .critical:
            let color: NSColor = summary.pressure == .critical ? .systemRed : .systemYellow
            let tinted = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
            tinted?.isTemplate = false
            return tinted
        case .normal, nil:
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

/// A menu item that runs a closure, enabled while `enabled` says so.
final class ActionMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    private let isAvailable: () -> Bool

    init(title: String, keyEquivalent: String = "", enabled: @escaping () -> Bool = { true }, action: @escaping () -> Void) {
        handler = action
        isAvailable = enabled
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder _: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }

    func validateMenuItem(_: NSMenuItem) -> Bool { isAvailable() }
}

/// The application menu. An accessory app shows no menu bar, but its key equivalents (⌘, ⌘Q ⌘W ⌘M, and the View
/// menu's ⌘1–⌘4 and ⌘F) still work while one of its windows is key.
@MainActor
enum MainMenu {
    /// `mainWindowIsKey` keeps the View menu's shortcuts to the System window, so ⌘F typed in Settings does nothing.
    static func make(perform: @escaping (ShellCommand) -> Void, processes: ProcessesWindowModel,
                     mainWindowIsKey: @escaping () -> Bool) -> NSMenu {
        let appMenu = NSMenu(title: SystemIdentity.appName)
        appMenu.addItem(CommandMenuItem(command: .about, perform: perform))
        appMenu.addItem(.separator())
        appMenu.addItem(CommandMenuItem(command: .settings, perform: perform))
        appMenu.addItem(.separator())
        appMenu.addItem(CommandMenuItem(command: .quit, title: "Quit \(SystemIdentity.appName)", perform: perform))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let viewMenu = NSMenu(title: "View")
        for (index, layer) in AttributionLayer.allCases.enumerated() {
            viewMenu.addItem(ActionMenuItem(title: "By \(layer.title)", keyEquivalent: String(index + 1), enabled: mainWindowIsKey) {
                processes.layer = layer
            })
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(ActionMenuItem(title: "Filter by Name", keyEquivalent: "f", enabled: mainWindowIsKey) {
            processes.focusFilter()
        })

        let mainMenu = NSMenu()
        for submenu in [appMenu, viewMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return mainMenu
    }
}
