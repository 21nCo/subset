import Foundation

/// Reports running apps, displays, and each app's windows. `AXWindowSource` in the host reads them through the
/// Accessibility API; `FixtureWindowSource` replays fixed data in tests.
///
/// `WindowLister` calls `apps()` and `displays()` on its own thread, then `windows(of:)` for several apps at once
/// from other threads, so a slow app does not hold up the others.
public protocol WindowSource: Sendable {
    /// The running apps, in the source's order.
    func apps() -> [SourceApp]
    /// The active displays.
    func displays() -> [SourceDisplay]
    /// One app's windows, in the source's order. Throws when the app does not answer in time or cannot be read.
    func windows(of app: SourceApp) throws(WindowSourceError) -> [SourceWindow]
}

public enum WindowSourceError: Error, Sendable, Equatable {
    /// The app did not answer within the per-app messaging timeout.
    case timedOut
    /// The app's windows could not be read for another reason.
    case failed
}

/// Fixed apps and windows for tests. Each app either answers with its windows or fails with an error; `update`
/// replaces the data between refreshes, for example to close a window.
public final class FixtureWindowSource: WindowSource, @unchecked Sendable {
    public struct App: Sendable {
        public var app: SourceApp
        public var windows: Result<[SourceWindow], WindowSourceError>

        public init(_ app: SourceApp, windows: [SourceWindow]) {
            self.app = app
            self.windows = .success(windows)
        }

        public init(_ app: SourceApp, failure: WindowSourceError) {
            self.app = app
            windows = .failure(failure)
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

    public func apps() -> [SourceApp] {
        lock.withLock { fixtureApps.map(\.app) }
    }

    public func displays() -> [SourceDisplay] {
        lock.withLock { fixtureDisplays }
    }

    public func windows(of app: SourceApp) throws(WindowSourceError) -> [SourceWindow] {
        let result = lock.withLock {
            queried.append(app.pid)
            return fixtureApps.first { $0.app.pid == app.pid }?.windows ?? .failure(.failed)
        }
        return try result.get()
    }
}
