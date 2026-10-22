import AppKit
import PointInTimeCore
import SwiftUI
import UserNotifications

/// The user's drift companion choices, persisted in the app's defaults. The companion is on with a threshold of two
/// drift blocks; quiet hours and the notification fallback are off until the user turns them on.
@MainActor
final class DriftSettings {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var enabled: Bool {
        get { defaults.object(forKey: "driftCompanionEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "driftCompanionEnabled"); onChange?() }
    }

    var threshold: Int {
        get { DriftRule(threshold: defaults.object(forKey: "driftThreshold") as? Int ?? DriftRule.defaultThreshold).threshold }
        set { defaults.set(DriftRule(threshold: newValue).threshold, forKey: "driftThreshold"); onChange?() }
    }

    var quietHoursEnabled: Bool {
        get { defaults.bool(forKey: "quietHoursEnabled") }
        set { defaults.set(newValue, forKey: "quietHoursEnabled"); onChange?() }
    }

    /// Minutes after local midnight; 22:00 to 07:00 until changed.
    var quietStartMinute: Int {
        get { defaults.object(forKey: "quietHoursStart") as? Int ?? 22 * 60 }
        set { defaults.set(newValue, forKey: "quietHoursStart"); onChange?() }
    }

    var quietEndMinute: Int {
        get { defaults.object(forKey: "quietHoursEnd") as? Int ?? 7 * 60 }
        set { defaults.set(newValue, forKey: "quietHoursEnd"); onChange?() }
    }

    /// Post a system notification when the panel cannot be shown. Turning it on is what asks macOS for permission.
    var notificationFallback: Bool {
        get { defaults.bool(forKey: "driftNotificationFallback") }
        set { defaults.set(newValue, forKey: "driftNotificationFallback"); onChange?() }
    }

    var rule: DriftRule {
        DriftRule(enabled: enabled, threshold: threshold,
                  quietHours: quietHoursEnabled ? QuietHours(startMinute: quietStartMinute, endMinute: quietEndMinute) : nil)
    }

    /// The companion's record of what it offered and the user's focus window and break, kept between launches.
    var companionState: CompanionState {
        get {
            let start = defaults.object(forKey: "focusWindowStart") as? Date
            let end = defaults.object(forKey: "focusWindowEnd") as? Date
            return CompanionState(promptedEpisode: defaults.object(forKey: "driftPromptedEpisode") as? Date,
                                  focusWindow: start.flatMap { start in end.map { DateInterval(start: start, end: max(start, $0)) } },
                                  breakUntil: defaults.object(forKey: "driftBreakUntil") as? Date)
        }
        set {
            defaults.set(newValue.promptedEpisode, forKey: "driftPromptedEpisode")
            defaults.set(newValue.focusWindow?.start, forKey: "focusWindowStart")
            defaults.set(newValue.focusWindow?.end, forKey: "focusWindowEnd")
            defaults.set(newValue.breakUntil, forKey: "driftBreakUntil")
        }
    }
}

/// Today's ring and the drift companion. After every classification run or correction, and every minute, it reads the
/// last day of blocks once, computes the ring from today's report totals, and asks `DriftDetector` whether a drift is
/// confirmed. A new one is offered in a panel by the menu bar item, or by notification when the user enabled that and
/// the panel cannot be shown. Each action is an explicit operation: Return to Focus records a focus window, Take a Break
/// pauses tracking, and Not a Drift writes corrections through the store's `correct`. None closes tabs, quits apps, or
/// sends anything anywhere.
@MainActor
final class DriftCompanionController: NSObject, UNUserNotificationCenterDelegate {
    static let lookBack: TimeInterval = 24 * 3_600

    let settings: DriftSettings
    private let store: ActivityStore?
    private let capture: CaptureController
    private let captureSettings: CaptureSettings
    private let classification: ClassificationController
    private let calendar = Calendar.autoupdatingCurrent
    private var timer: Timer?
    private lazy var panel = CompanionPanelController(companion: self)

    /// Today's ring; nil until the store has been read, or when it cannot be.
    private(set) var ring: FocusRing?
    private(set) var readError: String?
    /// The episode on offer while the panel is open.
    private(set) var offered: DriftEpisode?
    /// Why the last action could not finish, shown in the panel.
    private(set) var actionError: String?
    /// Whether macOS allows notifications, after the user turned the fallback on.
    private(set) var notificationsAllowed: Bool?
    /// Where the menu bar item is on screen, in screen coordinates; nil when it is not shown.
    var anchor: () -> NSRect? = { nil }
    /// Called after a refresh or an action, for the menu bar item.
    var onChange: (() -> Void)?

    init(settings: DriftSettings, store: ActivityStore?, capture: CaptureController, captureSettings: CaptureSettings,
         classification: ClassificationController) {
        self.settings = settings
        self.store = store
        self.capture = capture
        self.captureSettings = captureSettings
        self.classification = classification
        super.init()
    }

    var state: CompanionState { settings.companionState }

    func start() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if settings.notificationFallback { checkNotifications(request: false) }
        refresh()
    }

    /// Reads the store once, updates the ring, and offers a newly confirmed drift. Nothing is offered unless capture is
    /// recording: a drift noticed while paused, idle, asleep, or locked waits, and is offered only if it is still
    /// current once recording resumes.
    func refresh(now: Date = Date()) {
        defer { onChange?() }
        guard let store else {
            ring = nil
            readError = "The activity store is unavailable."
            return
        }
        let from = min(calendar.startOfDay(for: now), now.addingTimeInterval(-Self.lookBack))
        let blocks: [Block]
        do {
            blocks = try store.blocks(from: from, to: now.addingTimeInterval(Block.length))
            readError = nil
        } catch {
            ring = nil
            readError = String(describing: error)
            return
        }
        ring = FocusRing(today: now, blocks: blocks, calendar: calendar)
        var state = state
        if state.forgetOfferedEpisode(unlessIn: blocks, readFrom: from) { settings.companionState = state }
        guard capture.state == .recording,
              case .prompt(let episode) = DriftDetector.evaluate(blocks, now: now, rule: settings.rule, state: state, calendar: calendar) else { return }
        state.promptedEpisode = episode.start
        settings.companionState = state
        offer(episode)
    }

    func settingsChanged() {
        if !settings.enabled { dismiss() }
        refresh()
    }

    // MARK: Offering

    private func offer(_ episode: DriftEpisode) {
        offered = episode
        actionError = nil
        if panel.show(near: anchor()) { return }
        offered = nil
        if settings.notificationFallback { notify(episode) }
    }

    /// Closes the panel without acting; the episode stays offered, so it is not offered again.
    func dismiss() {
        offered = nil
        actionError = nil
        panel.close()
        onChange?()
    }

    /// The panel's text: how many blocks and since when.
    func summary(of episode: DriftEpisode) -> String {
        let count = episode.blockStarts.count
        let since = ReportText.time(episode.start, calendar: calendar, locale: .autoupdatingCurrent)
        return "\(count) recent block\(count == 1 ? " was" : "s were") labeled Drift, since \(since)."
    }

    // MARK: Actions

    /// Return to Focus: closes the panel and records a 25-minute focus window, during which no drift is offered and
    /// blocks are not counted toward one.
    func returnToFocus() {
        var state = state
        state.returnToFocus(at: Date())
        settings.companionState = state
        dismiss()
        refresh()
    }

    /// Ends the focus window early, from the menu.
    func endFocusWindow() {
        var state = state
        state.endFocusWindow(at: Date())
        settings.companionState = state
        refresh()
    }

    /// Take a Break: pauses tracking (when it is on) and drift prompts for `length`. An existing longer pause, such as
    /// one until the user resumes, is kept.
    func takeBreak(for length: TimeInterval) {
        let now = Date()
        var state = state
        let end = state.takeBreak(for: length, at: now)
        settings.companionState = state
        if captureSettings.onboardingCompleted, captureSettings.trackingEnabled,
           !(captureSettings.isPaused(at: now) && (captureSettings.pausedUntil ?? .distantPast) >= end) {
            // Ended first, like every control, so the open segment is saved before the pause.
            capture.endSegment()
            captureSettings.pausedUntil = end
        }
        dismiss()
        refresh()
    }

    /// Not a Drift: labels each of the episode's blocks `label` through the store's correction operation, which the
    /// next classification requests send as examples. The panel stays open with the error if any block could not be
    /// corrected (one deleted meanwhile, say); the others keep their correction.
    func notADrift(_ episode: DriftEpisode, as label: BlockLabel) {
        guard let store else { return }
        let now = Date()
        var failures: [String] = []
        for start in episode.blockStarts {
            do {
                try store.correct(blockStart: start, to: label, note: nil, at: now)
            } catch {
                failures.append("\(ReportText.time(start, calendar: calendar, locale: .autoupdatingCurrent)): \(error)")
            }
        }
        classification.refreshStatus()
        if failures.isEmpty {
            dismiss()
        } else {
            actionError = "Could not relabel every block. " + failures.joined(separator: "; ")
            panel.refresh()
        }
        refresh()
    }

    // MARK: Notification fallback

    private enum NotificationAction: String {
        case focus, breakTen, notDriftFocus, notDriftNeutral
    }

    private static let notificationCategory = "drift"

    /// UserNotifications needs an app bundle; a bare executable gets no notification center.
    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Asks macOS for permission when `request` is true (the user just turned the fallback on), otherwise only reads it.
    func checkNotifications(request: Bool) {
        guard let center = notificationCenter else {
            notificationsAllowed = false
            onChange?()
            return
        }
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.notificationCategory, actions: [
            UNNotificationAction(identifier: NotificationAction.focus.rawValue, title: "Return to Focus"),
            UNNotificationAction(identifier: NotificationAction.breakTen.rawValue, title: "Take a 10-Minute Break"),
            UNNotificationAction(identifier: NotificationAction.notDriftFocus.rawValue, title: "Not a Drift: Focus"),
            UNNotificationAction(identifier: NotificationAction.notDriftNeutral.rawValue, title: "Not a Drift: Neutral")
        ], intentIdentifiers: [])])
        let update: @Sendable (Bool) -> Void = { allowed in
            Task { @MainActor [weak self] in
                self?.notificationsAllowed = allowed
                self?.onChange?()
            }
        }
        if request {
            // Alerts only: the companion makes no sound.
            center.requestAuthorization(options: [.alert]) { allowed, _ in update(allowed) }
        } else {
            center.getNotificationSettings { settings in update(settings.authorizationStatus == .authorized) }
        }
    }

    private func notify(_ episode: DriftEpisode) {
        guard let center = notificationCenter, notificationsAllowed == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Drifting?"
        content.body = summary(of: episode)
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["blockStarts": episode.blockStarts.map(\.timeIntervalSince1970), "since": episode.since.timeIntervalSince1970]
        center.add(UNNotificationRequest(identifier: "drift-\(Int(episode.start.timeIntervalSince1970))", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = NotificationAction(rawValue: response.actionIdentifier)
        let info = response.notification.request.content.userInfo
        let starts = (info["blockStarts"] as? [Double] ?? []).map(Date.init(timeIntervalSince1970:))
        let since = (info["since"] as? Double).map(Date.init(timeIntervalSince1970:))
        await MainActor.run {
            switch action {
            case .focus: returnToFocus()
            case .breakTen: takeBreak(for: 10 * 60)
            case .notDriftFocus, .notDriftNeutral:
                guard let since, !starts.isEmpty else { return }
                notADrift(DriftEpisode(since: since, blockStarts: starts), as: action == .notDriftFocus ? .focus : .neutral)
            case nil: break
            }
        }
    }
}

/// The companion panel: a small non-activating panel under the menu bar item. Showing it does not activate pointInTime
/// or take keyboard focus from the app in front; it becomes key only when the user clicks it or moves to it with
/// VoiceOver. It closes itself after 60 seconds, and VoiceOver announces it when it appears.
@MainActor
final class CompanionPanelController: NSObject, NSWindowDelegate {
    static let lifetime: TimeInterval = 60

    private unowned let companion: DriftCompanionController
    private var panel: NSPanel?
    private var closeTimer: Timer?
    private let model = CompanionPanelModel()

    init(companion: DriftCompanionController) {
        self.companion = companion
    }

    /// Shows the offered episode under `anchor`; false when there is no anchor or screen to place it on.
    func show(near anchor: NSRect?) -> Bool {
        guard let anchor, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) else { return false }
        refresh()
        let panel = panel ?? makePanel()
        if let content = panel.contentViewController?.view { panel.setContentSize(content.fittingSize) }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(anchor.minY - 6, visible.maxY) - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, y)))
        panel.orderFrontRegardless()
        closeTimer?.invalidate()
        let timer = Timer(timeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.companion.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
        let text = model.episode.map { "pointInTime: drifting? \(companion.summary(of: $0)) Return to Focus, Take a Break, or Not a Drift." }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text ?? "pointInTime drift companion", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        return true
    }

    func refresh() {
        model.episode = companion.offered
        model.summary = companion.offered.map(companion.summary(of:)) ?? ""
        model.error = companion.actionError
    }

    func close() {
        closeTimer?.invalidate()
        closeTimer = nil
        panel?.orderOut(nil)
    }

    /// The close button dismisses, like the panel's Dismiss.
    func windowWillClose(_ notification: Notification) {
        closeTimer?.invalidate()
        closeTimer = nil
        if companion.offered != nil { companion.dismiss() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                            styleMask: [.nonactivatingPanel, .titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "pointInTime: Drifting?"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let hosting = NSHostingController(rootView: CompanionView(model: model, companion: companion))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.setAccessibilityLabel("pointInTime drift companion")
        self.panel = panel
        return panel
    }
}

@MainActor
final class CompanionPanelModel: ObservableObject {
    @Published var episode: DriftEpisode?
    @Published var summary = ""
    @Published var error: String?
}

/// Every action is a standard button, so it joins the keyboard focus loop and VoiceOver reads its full name. Escape
/// dismisses; nothing is the default button, so Return never acts by accident.
private struct CompanionView: View {
    @ObservedObject var model: CompanionPanelModel
    let companion: DriftCompanionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drifting?").font(.headline)
            Text(verbatim: model.summary).fixedSize(horizontal: false, vertical: true)
            Button("Return to Focus") { companion.returnToFocus() }
                .help("Start a 25-minute focus window. No drift prompts until it ends.")
                .accessibilityHint("Starts a 25-minute focus window with no drift prompts")
            HStack {
                Text("Take a Break:")
                ForEach(CompanionState.breakLengths, id: \.self) { length in
                    let minutes = Int(length / 60)
                    Button("\(minutes) min") { companion.takeBreak(for: length) }
                        .accessibilityLabel("Take a \(minutes)-minute break")
                        .accessibilityHint("Pauses tracking and drift prompts for \(minutes) minutes")
                }
            }
            HStack {
                Text("Not a Drift:")
                ForEach([BlockLabel.focus, .neutral], id: \.self) { label in
                    Button(label == .focus ? "Focus" : "Neutral") {
                        if let episode = model.episode { companion.notADrift(episode, as: label) }
                    }
                    .accessibilityLabel("Not a drift: label these blocks \(label == .focus ? "Focus" : "Neutral")")
                    .accessibilityHint("Saves a correction for each block, which later classification learns from")
                }
            }
            if let error = model.error {
                Text(verbatim: error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Dismiss") { companion.dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drift companion")
    }
}
