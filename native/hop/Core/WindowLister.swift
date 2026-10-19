import Foundation

/// Builds the switcher's window list from a `WindowSource`: applies `WindowFilter`, places each window on a display,
/// and orders the result with a `RecencyTracker`.
///
/// The list is rebuilt only when `refresh()` is called, when the switcher opens; focus changes in between only update
/// the recency order. Apps are read in parallel, so an app that times out costs the refresh its own timeout, not one
/// per app; it is left out of that refresh and counted in `skippedAppCount`, and the other apps are listed.
public struct WindowLister: Sendable {
    public let source: any WindowSource
    /// Hop's own process, whose windows are never listed.
    public let ownProcess: pid_t
    public private(set) var recency = RecencyTracker()
    /// How many times an app has been skipped since Hop started, for debugging.
    public private(set) var skippedAppCount = 0

    public init(source: any WindowSource, ownProcess: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.source = source
        self.ownProcess = ownProcess
    }

    /// Rebuilds the list. Windows that are no longer listed leave the recency order, except those of apps skipped
    /// this time.
    public mutating func refresh() -> WindowList {
        let (entries, list) = build()
        recency.retain(entries, keepingAppsOf: Set(list.skippedApps.map(\.pid)))
        return WindowList(windows: recency.ordered(entries), windowlessApps: list.windowlessApps, skippedApps: list.skippedApps)
    }

    /// Rebuilds the list and seeds the recency order from the window server's front-to-back order, at launch.
    public mutating func seed(frontToBack onScreen: [OnScreenWindow]) -> WindowList {
        let (entries, _) = build()
        recency.seed(entries, frontToBack: onScreen)
        return refresh()
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
        let results = Self.windows(of: apps, from: source)
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

    /// Each app's windows, in the apps' order, read concurrently.
    private static func windows(
        of apps: [SourceApp],
        from source: any WindowSource
    ) -> [Result<[SourceWindow], WindowSourceError>] {
        let results = ResultSlots(count: apps.count)
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            results.set(index, Result { () throws(WindowSourceError) in try source.windows(of: apps[index]) })
        }
        return results.values
    }
}

/// One result slot per app, written from `concurrentPerform`'s threads.
private final class ResultSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Result<[SourceWindow], WindowSourceError>]

    init(count: Int) {
        slots = Array(repeating: .failure(.failed), count: count)
    }

    func set(_ index: Int, _ result: Result<[SourceWindow], WindowSourceError>) {
        lock.withLock { slots[index] = result }
    }

    var values: [Result<[SourceWindow], WindowSourceError>] {
        lock.withLock { slots }
    }
}
