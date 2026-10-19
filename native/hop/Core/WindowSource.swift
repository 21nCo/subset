import Foundation

/// Reports running apps, displays, and each app's windows. `AXWindowSource` in the host reads them through the
/// Accessibility API; `FixtureWindowSource` replays fixed data in tests.
///
/// `WindowLister` calls `apps()` and `displays()` on its own thread, then `windows(of:until:)` for every app at once,
/// each on its own thread, so a slow app does not hold up the others.
public protocol WindowSource: Sendable {
    /// The running apps, in the source's order.
    func apps() -> [SourceApp]
    /// The active displays.
    func displays() -> [SourceDisplay]
    /// One app's windows, in the source's order. Every request the source makes to the app must give up at
    /// `deadline`, which bounds the whole read, not each request. Throws `.timedOut` when the app does not answer by
    /// then, and `.failed` when it cannot be read.
    func windows(of app: SourceApp, until deadline: ContinuousClock.Instant) throws(WindowSourceError) -> [SourceWindow]
}

public enum WindowSourceError: Error, Sendable, Equatable {
    /// The app did not answer within the per-app budget.
    case timedOut
    /// The app's windows could not be read for another reason.
    case failed
}

/// Fixed apps and windows for tests. Each app either answers with its windows or fails with an error, optionally
/// after a delay; `update` replaces the data between refreshes, for example to close a window.
public final class FixtureWindowSource: WindowSource, @unchecked Sendable {
    public struct App: Sendable {
        public var app: SourceApp
        public var windows: Result<[SourceWindow], WindowSourceError>
        /// How long the app takes to answer.
        public var delay: Duration
        /// Whether the app's reads give up at the deadline, as Accessibility requests with a messaging timeout do.
        /// An app that does not keeps the reading thread for its whole delay.
        public var honorsDeadline: Bool

        public init(_ app: SourceApp, windows: [SourceWindow], delay: Duration = .zero, honorsDeadline: Bool = true) {
            self.app = app
            self.windows = .success(windows)
            self.delay = delay
            self.honorsDeadline = honorsDeadline
        }

        public init(_ app: SourceApp, failure: WindowSourceError) {
            self.app = app
            windows = .failure(failure)
            delay = .zero
            honorsDeadline = true
        }
    }

    private let lock = NSLock()
    private var fixtureApps: [App]
    private var fixtureDisplays: [SourceDisplay]
    private var queried: [pid_t] = []

    public init(_ apps: [App], displays: [SourceDisplay] = []) {
        fixtureApps = apps
        fixtureDisplays = displays
    }

    public func update(_ apps: [App]) {
        lock.withLock { fixtureApps = apps }
    }

    /// The apps whose windows were asked for, in no particular order.
    public var queriedApps: Set<pid_t> {
        lock.withLock { Set(queried) }
    }

    /// How many times any app's windows were asked for.
    public var queryCount: Int {
        lock.withLock { queried.count }
    }

    public func apps() -> [SourceApp] {
        lock.withLock { fixtureApps.map(\.app) }
    }

    public func displays() -> [SourceDisplay] {
        lock.withLock { fixtureDisplays }
    }

    public func windows(of app: SourceApp, until deadline: ContinuousClock.Instant) throws(WindowSourceError) -> [SourceWindow] {
        let fixture = lock.withLock {
            queried.append(app.pid)
            return fixtureApps.first { $0.app.pid == app.pid }
        }
        guard let fixture else { throw .failed }
        if fixture.delay > .zero {
            let answered = ContinuousClock.now + fixture.delay
            guard fixture.honorsDeadline, answered > deadline else {
                Thread.sleep(forTimeInterval: Self.seconds(fixture.delay))
                return try fixture.windows.get()
            }
            Thread.sleep(forTimeInterval: Self.seconds(max(deadline - .now, .zero)))
            throw .timedOut
        }
        return try fixture.windows.get()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
