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
    private let classification: ClassificationController
    private let showWelcome: () -> Void
    private let showClassification: () -> Void

    init(settings: CaptureSettings, capture: CaptureController, store: ActivityStore?, classification: ClassificationController,
         showWelcome: @escaping () -> Void, showClassification: @escaping () -> Void) {
        self.settings = settings
        self.capture = capture
        self.store = store
        self.classification = classification
        self.showWelcome = showWelcome
        self.showClassification = showClassification
        super.init()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let (symbol, label): (String, String) = switch capture.state {
        case .recording, .idle: ("record.circle", "pointInTime is tracking")
        case .paused: ("pause.circle", "pointInTime is paused")
        case .storeUnavailable: ("exclamationmark.circle", "pointInTime cannot open or read its activity store")
        case .writesBacklogged: ("exclamationmark.circle", "pointInTime cannot save to its activity store")
        case .clockBehind: ("clock.badge.exclamationmark", "pointInTime is not recording until the clock passes recorded activity")
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
                // Ended first, like every control: each settings change samples, and turning tracking on begins the
                // first window read, which ending the segment afterwards would void.
                self.capture.endSegment()
                self.settings.trackingEnabled.toggle()
                self.settings.pausedUntil = nil
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
        menu.addItem(disabled(classificationLine()))
        menu.addItem(action("Classification…", showClassification))
        menu.addItem(.separator())
        menu.addItem(action("Delete Today’s Data…") { [weak self] in self?.confirmDelete(all: false) })
        menu.addItem(action("Delete All Data…") { [weak self] in self?.confirmDelete(all: true) })
        menu.addItem(.separator())
        menu.addItem(action("Welcome and Permissions…", showWelcome))
        menu.addItem(action("Quit pointInTime", key: "q") { [weak self] in self?.quit() })
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
        case .storeUnavailable: "Tracking unavailable: the activity store could not be opened or read"
        case .writesBacklogged: "Not recording until the activity store accepts the queued writes"
        case .clockBehind: "Not recording until the clock passes the latest recorded activity"
        }
    }

    private func classificationLine() -> String {
        guard classification.settings.provider != .off else { return "Classification: off" }
        let status = classification.status
        return status.lastError != nil && status.pending > 0
            ? "Classification: \(status.pending) pending, retrying"
            : "Classification: \(status.pending) pending"
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
        capture.endSegment()
        settings.pausedUntil = date
    }

    private func confirmDelete(all: Bool) {
        guard store != nil else { return }
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
        if let error = capture.deleteActivity(all: all) {
            let failure = NSAlert()
            failure.messageText = "Could not delete activity yet"
            failure.informativeText = "While pointInTime keeps running, it retries the deletion every few seconds and shows the error in its menu until it succeeds. Quitting pointInTime before then cancels the deletion, and the activity stays on this Mac.\n\n\(error)"
            failure.runModal()
        }
    }

    /// Queued writes live only in memory. Quitting first applies every one that storage accepts; if some still fail,
    /// quitting would lose them, so ask first.
    private func quit() {
        capture.finishWrites()
        let unsaved = capture.hasUnsavedActivity
        let deletion = capture.hasPendingDeletion
        if unsaved || deletion {
            var losses: [String] = []
            if unsaved {
                losses.append("Some recorded activity could not be saved yet. Quitting discards it, so that time will be missing.")
            }
            if deletion {
                losses.append("A deletion you asked for, or the removal of time recorded while you were idle, has not succeeded yet. Quitting cancels it, and that activity stays on this Mac.")
            }
            let alert = NSAlert()
            alert.messageText = "Quit before pointInTime finishes writing?"
            alert.informativeText = (losses + [capture.lastError].compactMap { $0 }).joined(separator: "\n\n")
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit Anyway")
            alert.buttons.last?.hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        NSApp.terminate(nil)
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
