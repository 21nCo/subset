import Foundation

/// Builds the switcher's window list from a `WindowSource`: applies `WindowFilter`, places each window on a display,
/// and orders the result with a `RecencyTracker`.
///
/// The list is rebuilt only when `refresh()` is called, when the switcher opens; focus changes in between only update
/// the recency order. Every app is read at once, each on its own thread, and every app's read must finish within
/// `appBudget` of the refresh's start, so a refresh takes at most `appBudget` plus `budgetGrace` however many apps are
/// slow. An app that does not answer in time is left out of that refresh and counted in `skippedAppCount`, and the
/// other apps are listed.
public struct WindowLister: Sendable {
    /// How long an app may take to report all of its windows: the per-app messaging timeout.
    public static let defaultAppBudget: Duration = .milliseconds(250)
    /// How long past the budget a refresh waits for a read that overran it before skipping that app anyway.
    public static let budgetGrace: Duration = .milliseconds(50)

    public let source: any WindowSource
    /// Hop's own process, whose windows are never listed.
    public let ownProcess: pid_t
    public let appBudget: Duration
    public private(set) var recency = RecencyTracker()
    /// How many times an app has been skipped since Hop started, for debugging.
    public private(set) var skippedAppCount = 0

    public init(
        source: any WindowSource,
        ownProcess: pid_t = ProcessInfo.processInfo.processIdentifier,
        appBudget: Duration = defaultAppBudget
    ) {
        self.source = source
        self.ownProcess = ownProcess
        self.appBudget = appBudget
    }

    /// Rebuilds the list. Windows that are no longer listed leave the recency order, except those of apps skipped
    /// this time.
    public mutating func refresh() -> WindowList {
        let (entries, list) = build()
        recency.retain(entries, keepingAppsOf: Set(list.skippedApps.map(\.pid)))
        return ordered(entries, list)
    }

    /// Rebuilds the list and seeds the recency order from the window server's front-to-back order, at launch. The
    /// apps are read once, for both.
    public mutating func seed(frontToBack onScreen: [OnScreenWindow]) -> WindowList {
        let (entries, list) = build()
        recency.retain(entries, keepingAppsOf: Set(list.skippedApps.map(\.pid)))
        recency.seed(entries, frontToBack: onScreen)
        return ordered(entries, list)
    }

    public mutating func noteFocused(_ ref: WindowRef, pid: pid_t) {
        recency.noteFocused(ref, pid: pid)
    }

    @discardableResult
    public mutating func noteActivated(pid: pid_t) -> Bool {
        recency.noteActivated(pid: pid)
    }

    public mutating func forgetApp(pid: pid_t) {
        recency.forgetApp(pid: pid)
    }

    /// The listed windows in source order, plus the windowless and skipped apps.
    private mutating func build() -> ([WindowEntry], WindowList) {
        // Excluded apps are never asked for their windows. For Hop itself that matters beyond cost: an Accessibility
        // request to its own process from a worker thread, while the main thread waits here, could never be answered.
        let apps = source.apps().filter { WindowFilter.exclusion(for: $0, ownProcess: ownProcess) == nil }
        let displays = source.displays()
        let deadline = ContinuousClock.now + appBudget
        let results = Self.windows(of: apps, from: source, until: deadline, waitingUntil: deadline + Self.budgetGrace)
        var entries: [WindowEntry] = []
        var listed = Set<WindowRef>()
        var list = WindowList()
        for (app, result) in zip(apps, results) {
            switch result {
            case let .failure(reason):
                list.skippedApps.append(SkippedApp(pid: app.pid, reason: reason))
            case let .success(windows):
                let before = entries.count
                for window in windows where WindowFilter.exclusion(for: window) == nil {
                    // A ref the source repeats is one window; the first report stands.
                    guard let frame = window.frame, listed.insert(window.ref).inserted else { continue }
                    let display = SourceDisplay.display(for: frame, among: displays)
                    entries.append(WindowEntry(app: app, window: window, frame: frame, display: display))
                }
                if entries.count == before { list.windowlessApps.append(AppEntry(app)) }
            }
        }
        skippedAppCount += list.skippedApps.count
        return (entries, list)
    }

    private func ordered(_ entries: [WindowEntry], _ list: WindowList) -> WindowList {
        WindowList(windows: recency.ordered(entries), windowlessApps: list.windowlessApps, skippedApps: list.skippedApps)
    }

    /// Each app's windows, in the apps' order. Every app is read on its own thread, rather than on a pool as wide as
    /// the CPU count, so apps waiting on their deadline never delay the reading of others. An app whose read has not
    /// finished at `cutoff` counts as timed out, and its result is ignored when it arrives.
    private static func windows(
        of apps: [SourceApp],
        from source: any WindowSource,
        until deadline: ContinuousClock.Instant,
        waitingUntil cutoff: ContinuousClock.Instant
    ) -> [Result<[SourceWindow], WindowSourceError>] {
        let results = ResultSlots(count: apps.count)
        let group = DispatchGroup()
        for (index, app) in apps.enumerated() {
            group.enter()
            let thread = Thread {
                results.set(index, Result { () throws(WindowSourceError) in try source.windows(of: app, until: deadline) })
                group.leave()
            }
            // The user is waiting for the list; a lower class lets the system stretch the reads' timeouts.
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        let wait = max(cutoff - .now, .zero)
        _ = group.wait(timeout: .now() + .microseconds(Int(wait / .microseconds(1))))
        return results.values
    }
}

/// One result slot per app, written from the reading threads. A slot still empty when it is read is an app that
/// did not answer in time.
private final class ResultSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Result<[SourceWindow], WindowSourceError>?]

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ result: Result<[SourceWindow], WindowSourceError>) {
        lock.withLock { slots[index] = result }
    }

    var values: [Result<[SourceWindow], WindowSourceError>] {
        lock.withLock { slots.map { $0 ?? .failure(.timedOut) } }
    }
}
