import AppKit
import TimerCore

/// The menu bar item and its menu. The item shows the running timer that ends soonest, else the app's glyph. Times
/// are projected from the daemon's timestamps: the item updates about once a second, and the open menu does too.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let controller: TimerController
    private let countdown: CountdownWindowController
    private var ticker: Timer?
    private var menuOpen = false
    /// The open menu's timer rows, updated in place every second.
    private var rows: [(item: NSMenuItem, timer: StoredTimer, status: TimerStatus)] = []

    init(controller: TimerController) {
        self.controller = controller
        countdown = CountdownWindowController(controller: controller)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        controller.onChange = { [weak self] in self?.changed() }
        controller.onError = { [weak self] message in self?.showError(message) }
        tick()
    }

    private static var now: Int { Int((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    private func changed() {
        if menuOpen { rebuild() }
        tick()
    }

    /// Updates the item (and the open menu), then waits for the next second the soonest timer shows.
    private func tick() {
        ticker?.invalidate()
        let now = Self.now
        let soonest = TimerFormat.soonest(controller.timers, now: now)
        if let soonest {
            let time = TimerFormat.duration(soonest.remainingMs, rounding: .up)
            item.button?.image = nil
            item.button?.attributedTitle = NSAttributedString(string: time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
            item.button?.setAccessibilityLabel("Timer: \(soonest.timer.definition.name), \(time) left")
        } else {
            item.button?.title = ""
            item.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
            item.button?.setAccessibilityLabel(statusLabel())
        }
        if menuOpen {
            // A timer that finished while the menu is open gets the controls of a finished timer.
            if rows.contains(where: { Projection.project($0.timer, now: now).status != $0.status }) { rebuild() }
            for row in rows { row.item.title = Self.title(row.timer, now: now) }
        }
        // Time left rounds up, so the shown second changes when the time left reaches a whole second.
        let wait = soonest.map { Double(max(1, ($0.remainingMs - 1) % 1000 + 1)) / 1000 } ?? 1
        let next = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = 0.05
        // The common modes keep it firing while the menu is open.
        RunLoop.main.add(next, forMode: .common)
        ticker = next
    }

    private func statusLabel() -> String {
        switch controller.setup {
        case .problem(let problem): "Timer: \(problem.message)"
        case .locating: "Timer: starting"
        case .ready: (controller.connectionProblem ?? controller.stateProblem).map { "Timer: \($0)" } ?? "Timer: no timer running"
        }
    }

    private static func title(_ timer: StoredTimer, now: Int) -> String {
        "\(timer.definition.name) — \(TimerFormat.state(timer, now: now))"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        controller.refreshPresets()
        controller.checkNotifications()
        tick()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        rows = []
    }

    private func rebuild() {
        menu.removeAllItems()
        rows = []
        switch controller.setup {
        case .locating:
            menu.addItem(disabled("Looking for Node.js…"))
        case .problem(let problem):
            menu.addItem(disabled(problem.message))
            if problem == .nodeMissing {
                menu.addItem(action("Download Node.js from nodejs.org…") { NSWorkspace.shared.open(URL(string: "https://nodejs.org/")!) })
            }
            menu.addItem(action("Check Again") { [controller] in controller.start() })
        case .ready:
            if let problem = controller.connectionProblem {
                menu.addItem(disabled("Reconnecting to the Timer daemon…"))
                menu.addItem(disabled(problem))
                menu.addItem(.separator())
            } else if let problem = controller.stateProblem {
                menu.addItem(disabled(problem))
                menu.addItem(.separator())
            }
            let now = Self.now
            if controller.timers.isEmpty { menu.addItem(disabled("No timers")) }
            for timer in controller.timers {
                let row = NSMenuItem(title: Self.title(timer, now: now), action: nil, keyEquivalent: "")
                row.submenu = controls(for: timer, now: now)
                menu.addItem(row)
                rows.append((row, timer, Projection.project(timer, now: now).status))
            }
            menu.addItem(.separator())
            menu.addItem(startItem())
            menu.addItem(action("New Countdown…") { [countdown] in countdown.show() })
            menu.addItem(action("Open Board") { [controller] in controller.openBoard() })
        }
        menu.addItem(.separator())
        menu.addItem(action("About Timer") { [weak self] in self?.showAbout() })
        menu.addItem(action("Quit Timer", key: "q") { NSApp.terminate(nil) })
    }

    /// The controls that apply to the timer as it stands now.
    private func controls(for timer: StoredTimer, now: Int) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let (definition, id) = (timer.definition, OperationInput(id: timer.definition.id))
        let status = Projection.project(timer, now: now).status
        let run: (String) -> () -> Void = { [controller] operation in { controller.run(operation, id) } }
        switch status {
        case .idle: submenu.addItem(action("Start", run("start")))
        case .running: submenu.addItem(action("Pause", run("pause")))
        case .paused: submenu.addItem(action("Resume", run("resume")))
        case .finished: break
        }
        if definition.takesLaps, status == .running { submenu.addItem(action("Lap", run("lap"))) }
        if definition.kind == .interval, status == .running || status == .paused { submenu.addItem(action("Skip", run("skip"))) }
        if status != .idle {
            submenu.addItem(action("Reset…") { [weak self] in
                self?.confirm("Reset “\(definition.name)”?", "It goes back to the start, and its laps are cleared.", button: "Reset", run("reset"))
            })
        }
        submenu.addItem(action("Remove…") { [weak self] in
            self?.confirm("Remove “\(definition.name)”?", "The timer is deleted. This cannot be undone.", button: "Remove", run("remove"))
        })
        return submenu
    }

    private func startItem() -> NSMenuItem {
        let start = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let builtIn = controller.presets.filter(\.builtIn)
        let saved = controller.presets.filter { !$0.builtIn }
        for preset in builtIn + saved {
            if preset.id == saved.first?.id, !builtIn.isEmpty { submenu.addItem(.separator()) }
            submenu.addItem(action(preset.name) { [controller] in controller.run("start", OperationInput(preset: preset.id)) })
        }
        if controller.presets.isEmpty { submenu.addItem(disabled("Loading presets…")) }
        start.submenu = submenu
        return start
    }

    // MARK: Dialogs

    private func confirm(_ message: String, _ detail: String, button: String, _ then: @escaping () -> Void) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { then() }
    }

    private func showError(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Timer could not do that"
        alert.informativeText = message
        alert.runModal()
    }

    /// The standard About panel, with where the app found its runtime or the setup problem.
    private func showAbout() {
        let details: String = switch controller.setup {
        case .locating: "Looking for Node.js…"
        case .problem(let problem): "Setup problem: \(problem.message)."
        case .ready(let runtime):
            """
            Node.js \(runtime.nodeVersion) at \(runtime.node)
            Timer CLI (\(runtime.cliSource.rawValue)) at \(runtime.cli)
            Daemon socket: \(controller.paths.socket)
            \(controller.connectionProblem.map { "Connection: \($0)" } ?? "Connected to the daemon.")
            \(Self.alertsLine(controller.alerts.registration))
            """ + (controller.stateProblem.map { "\nTimer state: \($0)" } ?? "")
        }
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: details, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])])
    }

    private static func alertsLine(_ registration: AlertHandler.Registration) -> String {
        switch registration {
        case .registered: "Alerts: played by this app."
        case .inactive: "Alerts: played by the daemon (notifications are off for Timer, or it is not connected)."
        case .refused(let reason): "Alerts: played by the daemon or another app (\(reason))."
        }
    }

    // MARK: Items

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, key: String = "", _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, handler: handler)
        item.isEnabled = true
        return item
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}
