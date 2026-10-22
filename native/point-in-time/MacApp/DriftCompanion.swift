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

    private var stored: StoredSettings { StoredSettings { [defaults] in defaults.object(forKey: $0) } }

    var enabled: Bool {
        get { stored.driftCompanionEnabled }
        set { defaults.set(newValue, forKey: StoredSettings.Key.driftCompanionEnabled); onChange?() }
    }

    var threshold: Int {
        get { stored.driftThreshold }
        set { defaults.set(DriftRule(threshold: newValue).threshold, forKey: StoredSettings.Key.driftThreshold); onChange?() }
    }

    var quietHoursEnabled: Bool {
        get { stored.quietHoursEnabled }
        set { defaults.set(newValue, forKey: StoredSettings.Key.quietHoursEnabled); onChange?() }
    }

    /// Minutes after local midnight; 22:00 to 07:00 until changed.
    var quietStartMinute: Int {
        get { stored.quietStartMinute }
        set { defaults.set(newValue, forKey: StoredSettings.Key.quietHoursStart); onChange?() }
    }

    var quietEndMinute: Int {
        get { stored.quietEndMinute }
        set { defaults.set(newValue, forKey: StoredSettings.Key.quietHoursEnd); onChange?() }
    }

    /// Post a system notification when the panel cannot be shown. Turning it on is what asks macOS for permission.
    var notificationFallback: Bool {
        get { defaults.bool(forKey: StoredSettings.Key.driftNotificationFallback) }
        set { defaults.set(newValue, forKey: StoredSettings.Key.driftNotificationFallback); onChange?() }
    }

    var rule: DriftRule { stored.driftRule }

    /// The companion's record of what it offered and the user's focus window and break, kept between launches.
    var companionState: CompanionState {
        get { stored.companionState }
        set {
            defaults.set(newValue.promptedEpisode, forKey: StoredSettings.Key.driftPromptedEpisode)
            defaults.set(newValue.focusWindow?.start, forKey: StoredSettings.Key.focusWindowStart)
            defaults.set(newValue.focusWindow?.end, forKey: StoredSettings.Key.focusWindowEnd)
            defaults.set(newValue.breakUntil, forKey: StoredSettings.Key.driftBreakUntil)
        }
    }
}

/// Today's ring and the drift companion, hosting `DriftCompanionFlow`, which orders its steps. After every
/// classification run or correction, and every minute, the flow reads the last day of blocks once, the ring is computed
/// from today's report totals, and `DriftDetector` says whether a drift is confirmed. A new one is offered in a panel by
/// the menu bar item, or by notification when the user enabled that and the panel cannot be shown; it is recorded as
/// offered once the panel showed it or macOS accepted the notification. Each action is an explicit operation: Return to
/// Focus records a focus window, Take a Break pauses tracking, and Not a Drift writes corrections through the store's
/// `correct`. None closes tabs, quits apps, or sends anything anywhere.
@MainActor
final class DriftCompanionController: NSObject, DriftCompanionHost, UNUserNotificationCenterDelegate {
    static let lookBack = DriftDetector.lookBack

    let settings: DriftSettings
    private let store: ActivityStore?
    private let capture: CaptureController
    private let captureSettings: CaptureSettings
    private let classification: ClassificationController
    private let calendar = Calendar.autoupdatingCurrent
    private let flow: DriftCompanionFlow
    private var timer: Timer?
    private lazy var panel = CompanionPanelController(companion: self)

    /// Today's ring; nil until the store has been read, or when it cannot be.
    private(set) var ring: FocusRing?
    private(set) var readError: String?
    /// Whether macOS allows pointInTime's alerts, as last read; nil until read. Read again before every notification.
    private(set) var notificationsAllowed: Bool?
    /// Why the last notification was not sent, shown in the menu until one is.
    private(set) var notificationError: String?
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
        flow = DriftCompanionFlow(calendar: calendar)
        super.init()
        flow.host = self
    }

    var state: CompanionState { settings.companionState }
    /// The episode on offer while the panel is open.
    var offered: DriftEpisode? { flow.onOffer }
    /// Why the last action could not finish, shown in the panel.
    var actionError: String? { flow.actionError }

    func start() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        setUpNotifications()
        if settings.notificationFallback { readNotificationPermission() }
        refresh()
    }

    func refresh() { flow.refresh(now: Date()) }

    func settingsChanged() {
        if !settings.notificationFallback { notificationError = nil }
        flow.settingsChanged(at: Date())
    }

    func dismiss() { flow.dismiss() }
    func returnToFocus() { flow.returnToFocus(at: Date()) }
    func endFocusWindow() { flow.endFocusWindow(at: Date()) }
    func takeBreak(for length: TimeInterval) { flow.takeBreak(for: length, at: Date()) }
    func notADrift(_ episode: DriftEpisode, as label: BlockLabel) { flow.notADrift(episode, as: label, at: Date()) }

    /// The panel's text: how many blocks and since when.
    func summary(of episode: DriftEpisode) -> String {
        let count = episode.blockStarts.count
        let since = ReportText.time(episode.start, calendar: calendar, locale: .autoupdatingCurrent)
        return "\(count) recent block\(count == 1 ? " was" : "s were") labeled Drift, since \(since)."
    }

    // MARK: DriftCompanionHost

    var companionState: CompanionState {
        get { settings.companionState }
        set { settings.companionState = newValue }
    }

    var driftRule: DriftRule { settings.rule }
    var notificationFallback: Bool { settings.notificationFallback }
    var isRecording: Bool { capture.state == .recording }

    func readBlocks(now: Date) -> (blocks: [Block], from: Date)? {
        guard let store else {
            ring = nil
            readError = "The activity store is unavailable."
            return nil
        }
        let from = min(calendar.startOfDay(for: now), now.addingTimeInterval(-Self.lookBack))
        do {
            let blocks = try store.blocks(from: from, to: now.addingTimeInterval(Block.length))
            readError = nil
            ring = FocusRing(today: now, blocks: blocks, calendar: calendar)
            return (blocks, from)
        } catch {
            ring = nil
            readError = String(describing: error)
            return nil
        }
    }

    func showPanel() -> Bool { panel.show(near: anchor()) }
    func closePanel() { panel.close() }
    func sendDriftNotification() { send(.drift) }
    func sendFailureNotification(_ message: String) { send(.failure(message)) }
    func companionChanged() { onChange?() }

    /// Pauses tracking (when it is on) until `end`. An existing longer pause, such as one until the user resumes, is kept.
    func pauseTracking(until end: Date, at now: Date) {
        guard captureSettings.onboardingCompleted, captureSettings.trackingEnabled,
              !(captureSettings.isPaused(at: now) && (captureSettings.pausedUntil ?? .distantPast) >= end) else { return }
        // Ended first, like every control, so the open segment is saved before the pause.
        capture.endSegment()
        captureSettings.pausedUntil = end
    }

    /// Corrections are what the next classification requests send as examples.
    func relabel(_ blockStarts: [Date], as label: BlockLabel, at now: Date) -> [String] {
        guard let store else { return ["The activity store is unavailable."] }
        var failures: [String] = []
        for start in blockStarts {
            do {
                try store.correct(blockStart: start, to: label, note: nil, at: now)
            } catch {
                failures.append("\(ReportText.time(start, calendar: calendar, locale: .autoupdatingCurrent)): \(error)")
            }
        }
        classification.refreshStatus()
        return failures
    }

    // MARK: Notification fallback

    private enum NotificationAction: String {
        case focus, breakTen, notDriftFocus, notDriftNeutral
    }

    /// What a notification carries: the drift on its way (the flow's `delivery.sending`), or why Not a Drift was not
    /// fully saved.
    private enum Outgoing: Sendable {
        case drift
        case failure(String)
    }

    private nonisolated static let driftCategory = "drift"
    private nonisolated static let failureCategory = "drift-error"

    /// UserNotifications needs an app bundle; a bare executable gets no notification center.
    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Handles notification actions and foreground presentation from launch, so an action on a notification sent before
    /// a relaunch still works. This asks macOS for nothing.
    private func setUpNotifications() {
        guard let center = notificationCenter else { return }
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.driftCategory, actions: [
            UNNotificationAction(identifier: NotificationAction.focus.rawValue, title: "Return to Focus"),
            UNNotificationAction(identifier: NotificationAction.breakTen.rawValue, title: "Take a 10-Minute Break"),
            UNNotificationAction(identifier: NotificationAction.notDriftFocus.rawValue, title: "Not a Drift: Focus"),
            UNNotificationAction(identifier: NotificationAction.notDriftNeutral.rawValue, title: "Not a Drift: Neutral")
        ], intentIdentifiers: [])])
    }

    /// Asks macOS for permission to show alerts, without sound. Called only when the user turns the fallback on.
    func requestNotifications() {
        guard let center = notificationCenter else {
            notificationsAllowed = false
            onChange?()
            return
        }
        center.requestAuthorization(options: [.alert]) { @Sendable _, _ in
            Task { @MainActor [weak self] in self?.readNotificationPermission() }
        }
    }

    /// Reads whether macOS allows pointInTime's alerts, for the settings window.
    private func readNotificationPermission() {
        guard let center = notificationCenter else { return }
        center.getNotificationSettings { @Sendable settings in
            let allowed = Self.alertsAllowed(settings)
            Task { @MainActor [weak self] in
                self?.notificationsAllowed = allowed
                self?.onChange?()
            }
        }
    }

    private nonisolated static func alertsAllowed(_ settings: UNNotificationSettings) -> Bool {
        settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
    }

    /// Sends `outgoing` if macOS allows pointInTime's alerts, read again each time because the user can turn them off in
    /// System Settings at any moment, and if it is still wanted once that read returns (see `submit`).
    private func send(_ outgoing: Outgoing) {
        guard let center = notificationCenter else {
            answered(outgoing, error: "Notifications need the pointInTime app.")
            return
        }
        // macOS calls back on its own queue; only the Sendable answer crosses to the main actor, never the center.
        center.getNotificationSettings { @Sendable settings in
            let allowed = Self.alertsAllowed(settings)
            Task { @MainActor [weak self] in self?.submit(outgoing, allowed: allowed) }
        }
    }

    /// Submits `outgoing` on the main actor right after the authorization read, if it is still wanted (see
    /// `submission`), then hands macOS's answer to `answered`.
    private func submit(_ outgoing: Outgoing, allowed: Bool) {
        notificationsAllowed = allowed
        guard allowed else {
            answered(outgoing, error: "Notifications for pointInTime are turned off in System Settings > Notifications.")
            return
        }
        guard let center = notificationCenter else {
            answered(outgoing, error: "Notifications need the pointInTime app.")
            return
        }
        guard let content = submission(for: outgoing) else {
            onChange?()
            return
        }
        center.add(Self.request(for: content)) { @Sendable error in
            let message = error.map { "The notification could not be sent: \($0.localizedDescription)" }
            Task { @MainActor [weak self] in self?.answered(outgoing, error: message) }
        }
    }

    /// What to submit for `outgoing` now, or nil when it is no longer wanted: the fallback was turned off, or, for a
    /// drift, a fresh read no longer offers it (see `DriftCompanionFlow.confirmSubmission`).
    private func submission(for outgoing: Outgoing) -> Submission? {
        switch outgoing {
        case .drift:
            guard let episode = flow.confirmSubmission(now: Date()) else { return nil }
            return .drift(episode, summary: summary(of: episode))
        case .failure(let message):
            return settings.notificationFallback ? .failure(message) : nil
        }
    }

    /// What a notification submitted shows: the drift with its summary, or why Not a Drift was not fully saved.
    private enum Submission: Sendable {
        case drift(DriftEpisode, summary: String)
        case failure(String)
    }

    private nonisolated static func request(for submission: Submission) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        switch submission {
        case .drift(let episode, let summary):
            content.title = "Drifting?"
            content.body = summary
            content.categoryIdentifier = driftCategory
            content.userInfo = ["blockStarts": episode.blockStarts.map(\.timeIntervalSince1970), "since": episode.since.timeIntervalSince1970]
            return UNNotificationRequest(identifier: "drift-\(Int(episode.start.timeIntervalSince1970))", content: content, trigger: nil)
        case .failure(let message):
            content.title = "Not a Drift was not fully saved"
            content.body = message
            content.categoryIdentifier = failureCategory
            return UNNotificationRequest(identifier: "drift-error-\(UUID().uuidString)", content: content, trigger: nil)
        }
    }

    /// macOS's answer for a notification: nil once it accepted it, else why not, which the menu shows until one is
    /// sent. A drift's answer goes to the flow (see `DriftCompanionFlow.deliveryAnswered`).
    private func answered(_ outgoing: Outgoing, error: String?) {
        notificationError = error
        guard case .drift = outgoing else {
            onChange?()
            return
        }
        flow.deliveryAnswered(accepted: error == nil, now: Date())
    }

    /// The fallback's notifications are shown while pointInTime is in front too (its reports or settings window, say), as
    /// a banner and in Notification Center, without sound.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        return category == Self.driftCategory || category == Self.failureCategory ? [.banner, .list] : []
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
        let text = model.error ?? model.episode.map { "pointInTime: drifting? \(companion.summary(of: $0)) Return to Focus, Take a Break, or Not a Drift." }
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
