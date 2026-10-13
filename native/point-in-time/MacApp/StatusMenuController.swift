import AppKit
import PointInTimeCore

/// The menu bar item and its menu. Every control is an explicit action on `CaptureSettings` or the store.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let settings: CaptureSettings
    private let capture: CaptureController
    private let store: ActivityStore?
    private let showWelcome: () -> Void

    init(settings: CaptureSettings, capture: CaptureController, store: ActivityStore?, showWelcome: @escaping () -> Void) {
        self.settings = settings
        self.capture = capture
        self.store = store
        self.showWelcome = showWelcome
        super.init()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let (symbol, label): (String, String) = switch capture.state {
        case .recording, .idle: ("record.circle", "pointInTime is tracking")
        case .paused: ("pause.circle", "pointInTime is paused")
        case .storeUnavailable: ("exclamationmark.circle", "pointInTime cannot open its activity store")
        default: ("circle.dashed", "pointInTime is not tracking")
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.button?.setAccessibilityLabel(label)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusLine()))
        if let recorded = todayRecorded() { menu.addItem(disabled(recorded)) }
        if let error = capture.lastError { menu.addItem(disabled("Store error: \(error)")) }
        menu.addItem(disabled(AccessibilityAccess.isGranted ? "Window titles: Accessibility granted" : "Window titles: Accessibility not granted"))
        if !AccessibilityAccess.isGranted { menu.addItem(action("Grant Accessibility Access…") { AccessibilityAccess.request() }) }
        menu.addItem(.separator())

        if settings.onboardingCompleted {
            if settings.isPaused() {
                menu.addItem(action("Resume Tracking") { [settings] in settings.pausedUntil = nil })
            } else if settings.trackingEnabled {
                let pause = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.addItem(action("For 15 Minutes") { [weak self] in self?.pause(for: 15 * 60) })
                submenu.addItem(action("For 1 Hour") { [weak self] in self?.pause(for: 60 * 60) })
                submenu.addItem(action("Until I Resume") { [weak self] in self?.pause(until: .distantFuture) })
                pause.submenu = submenu
                menu.addItem(pause)
            }
            menu.addItem(action(settings.trackingEnabled ? "Turn Tracking Off" : "Turn Tracking On") { [weak self] in
                guard let self else { return }
                self.settings.trackingEnabled.toggle()
                self.settings.pausedUntil = nil
                self.capture.endSegment()
            })
        } else {
            menu.addItem(action("Set Up pointInTime…", showWelcome))
        }
        menu.addItem(.separator())

        if let app = capture.lastForeignApp, settings.excludedApps[app.bundleID] == nil {
            menu.addItem(action("Exclude \(app.name)") { [weak self] in
                guard let self else { return }
                self.capture.endSegment()
                self.settings.excludedApps[app.bundleID] = app.name
            })
        }
        menu.addItem(excludedAppsItem())
        menu.addItem(.separator())
        menu.addItem(action("Delete Today’s Data…") { [weak self] in self?.confirmDelete(all: false) })
        menu.addItem(action("Delete All Data…") { [weak self] in self?.confirmDelete(all: true) })
        menu.addItem(.separator())
        menu.addItem(action("Welcome and Permissions…", showWelcome))
        menu.addItem(action("Quit pointInTime", key: "q") { NSApp.terminate(nil) })
    }

    private func statusLine() -> String {
        switch capture.state {
        case .recording: "Tracking"
        case .idle: "Tracking (idle, not recording)"
        case .paused:
            if let until = settings.pausedUntil, until != .distantFuture {
                "Paused until \(until.formatted(date: .omitted, time: .shortened))"
            } else { "Paused" }
        case .off: settings.onboardingCompleted ? "Tracking is off" : "Not set up yet"
        case .asleep, .locked, .inactiveSession: "Not recording while the Mac is asleep, locked, or switched away"
        case .storeUnavailable: "Tracking unavailable: the activity store could not be opened"
        }
    }

    private func todayRecorded() -> String? {
        guard let store else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        guard let blocks = try? store.blocks(from: start, to: Date().addingTimeInterval(Block.length)) else { return nil }
        // Anonymous excluded time is recorded time too.
        let seconds = blocks.reduce(0) { $0 + $1.activeSeconds + $1.excludedSeconds }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return "Today: \(formatter.string(from: seconds) ?? "0m") recorded"
    }

    private func excludedAppsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Excluded Apps", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let excluded = settings.excludedApps.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        if excluded.isEmpty { submenu.addItem(disabled("No excluded apps")) }
        for (bundleID, name) in excluded {
            submenu.addItem(action("Include \(name) Again") { [weak self] in
                guard let self else { return }
                self.capture.endSegment()
                self.settings.excludedApps[bundleID] = nil
            })
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("While an excluded app is in front:"))
        for (mode, title) in [(ExclusionMode.timeOnly, "Record Anonymous Excluded Time"), (.nothing, "Record Nothing")] {
            let choice = action(title) { [weak self] in
                guard let self else { return }
                self.capture.endSegment()
                self.settings.exclusionMode = mode
            }
            choice.state = settings.exclusionMode == mode ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    private func pause(for seconds: TimeInterval) { pause(until: Date().addingTimeInterval(seconds)) }

    private func pause(until date: Date) {
        settings.pausedUntil = date
        capture.endSegment()
    }

    private func confirmDelete(all: Bool) {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = all ? "Delete all captured activity?" : "Delete today’s captured activity?"
        alert.informativeText = all
            ? "Every recorded segment and block is removed from this Mac. Your settings and excluded apps are kept. This cannot be undone."
            : "Everything recorded since midnight is removed from this Mac. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // End the open segment first so it cannot be written back after deletion.
        capture.endSegment()
        do {
            if all { try store.deleteAll() }
            else {
                try store.deleteData(from: Calendar.current.startOfDay(for: Date()), to: .distantFuture)
                try store.checkpoint()
            }
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not delete activity"
            failure.informativeText = String(describing: error)
            failure.runModal()
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, key: String = "", _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, handler: handler)
        return item
    }
}

/// A menu item that runs a closure, so menu construction stays declarative.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
