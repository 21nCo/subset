import AppKit
import PointInTimeCore

/// The menu bar item and its menu. Every control is an explicit action on `CaptureSettings`, the store, or the drift
/// companion. The item is a ring of today's focus, neutral, and drift shares of classified time, with a mark in its
/// middle while tracking is paused, off, or failing.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let settings: CaptureSettings
    private let capture: CaptureController
    private let store: ActivityStore?
    private let classification: ClassificationController
    private let companion: DriftCompanionController
    private let showWelcome: () -> Void
    private let showClassification: () -> Void
    private let showReports: () -> Void
    private let showDriftSettings: () -> Void

    init(settings: CaptureSettings, capture: CaptureController, store: ActivityStore?, classification: ClassificationController,
         companion: DriftCompanionController, showWelcome: @escaping () -> Void, showClassification: @escaping () -> Void,
         showReports: @escaping () -> Void, showDriftSettings: @escaping () -> Void) {
        self.settings = settings
        self.capture = capture
        self.store = store
        self.classification = classification
        self.companion = companion
        self.showWelcome = showWelcome
        self.showClassification = showClassification
        self.showReports = showReports
        self.showDriftSettings = showDriftSettings
        super.init()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    /// Redraws the ring from the companion's latest read of today's blocks, and the mark for the tracking state.
    func refreshIcon() {
        let (mark, state): (String?, String) = switch capture.state {
        case .recording, .idle: (nil, "pointInTime is tracking")
        case .paused: ("pause.fill", "pointInTime is paused")
        case .storeUnavailable: ("exclamationmark", "pointInTime cannot open or read its activity store")
        case .writesBacklogged: ("exclamationmark", "pointInTime cannot save to its activity store")
        case .clockBehind: ("clock", "pointInTime is not recording until the clock passes recorded activity")
        default: ("minus", "pointInTime is not tracking")
        }
        let today = companion.ring?.accessibilityText
            ?? (companion.readError == nil ? "Today’s balance has not been read yet" : "Today’s balance could not be read")
        let label = "\(state). \(today)."
        item.button?.image = Self.ringImage(companion.ring, mark: mark, label: label)
        item.button?.setAccessibilityLabel(label)
    }

    /// The menu bar item's frame on screen, where the companion panel is placed; nil while the item is not shown.
    func anchorFrame() -> NSRect? {
        guard item.isVisible, let window = item.button?.window, window.isVisible else { return nil }
        return window.frame
    }

    /// An 18-point ring: a faint track, then focus, neutral, and drift arcs clockwise from the top in the window's
    /// colors, each as long as its share of today's classified time. Drawn when shown, so the track and mark follow
    /// the menu bar's appearance.
    static func ringImage(_ ring: FocusRing?, mark: String?, label: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.5
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 3
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            track.stroke()
            var angle: CGFloat = 90
            for arc in ring?.arcs ?? [] {
                let end = angle - CGFloat(arc.fraction) * 360
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius, startAngle: angle, endAngle: end, clockwise: true)
                path.lineWidth = 3
                arc.category.menuBarColor.setStroke()
                path.stroke()
                angle = end
            }
            if let mark, let symbol = NSImage(systemSymbolName: mark, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))) {
                let size = symbol.size
                symbol.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
        image.accessibilityDescription = label
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusLine()))
        for line in todayLines() { menu.addItem(disabled(line)) }
        addCompanionItems(to: menu)
        menu.addItem(action("Open Timeline and Reports…", key: "t", showReports))
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
        menu.addItem(action("Drift Companion…", showDriftSettings))
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
        let provider = switch classification.settings.provider {
        case .off: ""
        case .openRouter: "OpenRouter"
        }
        guard !provider.isEmpty else { return "Classification: off" }
        let status = classification.status
        var line = "Classification (\(provider)): \(status.pending) pending"
        if status.failed > 0 { line += ", \(status.failed) failed" }
        if status.lastError != nil && status.pending > 0 { line += ", retrying" }
        return line
    }

    /// Today's recorded time and its focus, neutral, and drift, from the same day totals as the window.
    private func todayLines() -> [String] {
        guard let store else { return [] }
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        guard let blocks = try? store.blocks(from: calendar.startOfDay(for: now), to: now.addingTimeInterval(Block.length)) else {
            return ["Today: the activity store could not be read"]
        }
        let ring = FocusRing(today: now, blocks: blocks, calendar: calendar)
        // Anonymous excluded time is recorded time too.
        let recorded = "Today: \(ReportText.duration(ring.totals.recorded)) recorded"
        guard !ring.isEmpty else { return [recorded, "Nothing classified yet today"] }
        let shares = FocusRing.categories.map { category in
            "\(category.title) \(ReportText.duration(ring.totals[category])) (\(ReportText.percent(ring.totals.share(of: category) ?? 0)))"
        }
        return [recorded, shares.joined(separator: ", ")]
    }

    /// The focus window, and the companion's actions while it offers a drift, so each can be reached from the keyboard
    /// through the menu bar as well as in the panel.
    private func addCompanionItems(to menu: NSMenu) {
        let now = Date()
        if let window = companion.state.activeFocusWindow(at: now) {
            menu.addItem(disabled("Focus window until \(window.end.formatted(date: .omitted, time: .shortened))"))
            menu.addItem(action("End Focus Window") { [companion] in companion.endFocusWindow() })
        }
        if let error = companion.notificationError { menu.addItem(disabled("Drift notification not sent: \(error)")) }
        guard let episode = companion.offered else { return }
        menu.addItem(.separator())
        menu.addItem(disabled("Drifting? \(companion.summary(of: episode))"))
        if let error = companion.actionError { menu.addItem(disabled(error)) }
        menu.addItem(action("Return to Focus") { [companion] in companion.returnToFocus() })
        let rest = NSMenuItem(title: "Take a Break", action: nil, keyEquivalent: "")
        rest.submenu = NSMenu()
        for length in CompanionState.breakLengths {
            rest.submenu?.addItem(action("For \(Int(length / 60)) Minutes") { [companion] in companion.takeBreak(for: length) })
        }
        menu.addItem(rest)
        let notDrift = NSMenuItem(title: "Not a Drift", action: nil, keyEquivalent: "")
        notDrift.submenu = NSMenu()
        for label in [BlockLabel.focus, .neutral] {
            notDrift.submenu?.addItem(action("Label These Blocks \(label == .focus ? "Focus" : "Neutral")") { [companion] in
                companion.notADrift(episode, as: label)
            })
        }
        menu.addItem(notDrift)
        menu.addItem(action("Dismiss Drift Prompt") { [companion] in companion.dismiss() })
        menu.addItem(.separator())
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

extension TimeCategory {
    /// The window's category colors, for the menu bar ring.
    var menuBarColor: NSColor {
        switch self {
        case .focus: .systemGreen
        case .neutral: .systemBlue
        case .drift: .systemOrange
        case .unclassified: .systemGray
        case .excluded: .systemPurple
        }
    }
}
