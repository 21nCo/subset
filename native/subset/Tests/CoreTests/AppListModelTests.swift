import Combine
import Foundation
@testable import SubsetCore
import XCTest

/// Answers each load with the next recorded result and counts the loads.
final class RecordedLoader: CatalogLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<LoadedCatalog, CatalogError>]
    private(set) var loads = 0

    init(_ results: [Result<LoadedCatalog, CatalogError>]) {
        self.results = results
    }

    func load(refresh _: Bool) async -> Result<LoadedCatalog, CatalogError> {
        lock.withLock {
            loads += 1
            return results.isEmpty ? .failure(.unavailable("no recorded result")) : results.removeFirst()
        }
    }
}

/// Holds each load until the test finishes it, so a test can act while a fetch is in flight. A result finished before
/// the load arrives is kept for it, and once closed every waiting and later load ends at once, so no load is left
/// waiting when a test stops early.
final class GatedLoader: CatalogLoading, @unchecked Sendable {
    typealias LoadResult = Result<LoadedCatalog, CatalogError>
    static let closedResult: LoadResult = .failure(.unavailable("closed by the test"))

    private let lock = NSLock()
    private var waiting: CheckedContinuation<LoadResult, Never>?
    private var pending: LoadResult?
    private var closed = false

    var isWaiting: Bool { lock.withLock { waiting != nil } }

    func load(refresh _: Bool) async -> LoadResult {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> LoadResult? in
                if let pending {
                    self.pending = nil
                    return pending
                }
                if closed { return Self.closedResult }
                waiting = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func finish(_ result: LoadResult) {
        let continuation = lock.withLock { () -> CheckedContinuation<LoadResult, Never>? in
            defer { waiting = nil }
            if waiting == nil { pending = result }
            return waiting
        }
        continuation?.resume(returning: result)
    }

    func close() {
        let continuation = lock.withLock { () -> CheckedContinuation<LoadResult, Never>? in
            defer { waiting = nil }
            closed = true
            return waiting
        }
        continuation?.resume(returning: Self.closedResult)
    }
}

/// Detects with `finder`, except that call numbers `gatedCalls` (from 1) wait until `release`.
final class GatedFinder: InstalledAppDetecting, @unchecked Sendable {
    private let finder: InstalledAppFinder
    private let gatedCalls: Set<Int>
    /// A held call then reads the folders (a look held before it reads); otherwise it finds nothing (one that read
    /// before it was held).
    private let readsAfterGate: Bool
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var waiting = false
    private var held = 0

    convenience init(_ finder: InstalledAppFinder, gatedCall: Int) {
        self.init(finder, gatedCalls: [gatedCall])
    }

    init(_ finder: InstalledAppFinder, gatedCalls: Set<Int>, readsAfterGate: Bool = false) {
        self.finder = finder
        self.gatedCalls = gatedCalls
        self.readsAfterGate = readsAfterGate
    }

    var isWaiting: Bool { lock.withLock { waiting } }
    /// How many gated calls wait now, and how many calls were made.
    var holding: Int { lock.withLock { held } }
    var callCount: Int { lock.withLock { calls } }

    func detect(_ apps: [CatalogApp]) -> [String: [InstalledCopy]] {
        let call = lock.withLock { () -> Int in
            calls += 1
            if gatedCalls.contains(calls) {
                waiting = true
                held += 1
            }
            return calls
        }
        guard gatedCalls.contains(call) else { return finder.detect(apps) }
        gate.wait()
        lock.withLock { held -= 1 }
        return readsAfterGate ? finder.detect(apps) : [:]
    }

    func release() { gate.signal() }
}

/// What `waitUntil` throws when its condition did not hold in time.
struct WaitTimedOut: Error {}

/// Resumes a continuation once, with the first answer given.
final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func give(_ answer: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: answer)
    }
}

@MainActor
final class AppListModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var root: URL!
    private let clock = TestClock()

    override func setUp() async throws {
        suite = "subset-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("subset-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("apps"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var finder: InstalledAppFinder {
        InstalledAppFinder(
            folders: [ApplicationsFolder(label: "/Applications", path: "/Applications", directory: root.appendingPathComponent("apps"))],
            receipts: root.appendingPathComponent("receipts")
        )
    }

    private func model(_ results: [Result<LoadedCatalog, CatalogError>]) -> (AppListModel, RecordedLoader) {
        let loader = RecordedLoader(results)
        let clock = clock
        return (AppListModel(loader: loader, finder: finder, defaults: defaults, now: { clock.now }), loader)
    }

    private func loaded(_ name: String, warning: String? = nil) throws -> Result<LoadedCatalog, CatalogError> {
        let catalog = try Catalog.parse(try fixture(name)).get()
        return .success(LoadedCatalog(
            catalog: catalog, url: CatalogLocation.defaultURL, fetchedAt: clock.now, cached: warning != nil, warning: warning
        ))
    }

    private func install(_ name: String, _ bundleID: String, version: String, build: String = "1", receipt: [String: Any]? = nil) throws {
        let contents = root.appendingPathComponent("apps/\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        guard var receipt else { return }
        receipt.merge(["schema": "subset.receipt@1", "sha256": String(repeating: "b", count: 64), "installedAt": "2026-11-12T09:30:00Z",
                       "path": "/Applications/\(name).app", "version": version]) { old, _ in old }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("receipts"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: receipt).write(to: root.appendingPathComponent("receipts/\(bundleID).json"))
    }

    // MARK: Rows and the Update available badge

    func testEveryFeedAppIsListedWithWhatIsInstalledAndBetasHiddenByDefault() async throws {
        try install("Breaks", "dev.subset.breaks", version: "0.1.0")
        let (model, _) = model([try loaded("catalog-valid-live-and-beta")])
        XCTAssertFalse(model.showBetas)
        await model.refresh()
        XCTAssertEqual(model.status, .current)
        let rows = model.rows
        XCTAssertEqual(rows.map(\.id), ["breaks", "timer"])
        XCTAssertEqual(rows[0].installed.map(\.folder), ["/Applications"])
        XCTAssertEqual(rows[0].installed.map(\.versionLabel), ["0.1.0"])
        XCTAssertEqual(rows[0].live, "0.1.0")
        XCTAssertNil(rows[0].beta)
        XCTAssertNil(rows[0].update, "the live release is installed; the newer beta is hidden")
        XCTAssertEqual(rows[1].installed, [])
        XCTAssertNil(rows[1].live)
        XCTAssertNil(rows[1].update, "an app that is not installed has no update")
        XCTAssertEqual(model.updatesMenuTitle, "No updates available")
    }

    func testShowingBetasListsThemOffersANewerBetaAndIsRemembered() async throws {
        try install("Breaks", "dev.subset.breaks", version: "0.1.0")
        let (model, _) = model([try loaded("catalog-valid-live-and-beta")])
        await model.refresh()
        model.showBetas = true
        XCTAssertEqual(model.rows.map(\.beta), ["0.1.1-beta.4", "0.1.0-beta.2"])
        XCTAssertEqual(model.rows[0].update, "0.1.1-beta.4")
        XCTAssertEqual(model.updatesMenuTitle, "1 update available")
        XCTAssertTrue(defaults.bool(forKey: AppListModel.showBetasKey))
        XCTAssertTrue(AppListModel(loader: RecordedLoader([]), finder: finder, defaults: defaults).showBetas)
    }

    func testANewerLiveVersionShowsTheBadge() async throws {
        try install("Breaks", "dev.subset.breaks", version: "0.0.9")
        let (model, _) = model([try loaded("catalog-valid-live-only")])
        await model.refresh()
        XCTAssertEqual(model.rows[0].update, "0.1.0")
        XCTAssertEqual(model.updateCount, 1)
        XCTAssertEqual(model.updatesMenuTitle, "1 update available")
    }

    func testNoBadgeForANewerCopyOrAnUnknownVersion() async throws {
        let (model, _) = model([try loaded("catalog-valid-live-only"), try loaded("catalog-valid-live-only")])
        try install("Breaks", "dev.subset.breaks", version: "0.10.0")
        await model.refresh()
        XCTAssertNil(model.rows[0].update, "0.10.0 is newer than 0.1.0")
        try install("Breaks", "dev.subset.breaks", version: "1.0")
        await model.refresh()
        XCTAssertNil(model.rows[0].update)
    }

    func testABetaByItsReceiptIsOfferedTheLiveReleaseOfItsVersionAndANewerBuild() throws {
        let app = try Catalog.parse(try fixture("catalog-valid-live-and-beta")).get().apps[0]
        let beta = InstalledCopy(path: "/Applications/Breaks.app", folder: "/Applications", version: "0.1.1", build: "3", channel: .beta)
        let noReceipt = InstalledCopy(path: "/Applications/Breaks.app", folder: "/Applications", version: "0.1.1", build: "3", channel: nil)
        // Live is 0.1.0, older than this beta, so there is no live update; with betas shown, build 4 is newer than 3.
        XCTAssertNil(AppListModel.offeredRelease(app, [beta], showBetas: false)?.label)
        XCTAssertEqual(AppListModel.offeredRelease(app, [beta], showBetas: true)?.label, "0.1.1-beta.4")
        XCTAssertNil(AppListModel.offeredRelease(app, [noReceipt], showBetas: true)?.label, "without a receipt builds are not compared")
        var released = app
        released.live?.version = "0.1.1"
        XCTAssertEqual(AppListModel.offeredRelease(released, [beta], showBetas: false)?.label, "0.1.1")
        XCTAssertEqual(AppListModel.offeredRelease(released, [beta], showBetas: true)?.label, "0.1.1", "a release is newer than its betas")
        XCTAssertNil(AppListModel.offeredRelease(released, [noReceipt], showBetas: true)?.label)
    }

    func testVersionsCompareByNumberNotText() {
        XCTAssertEqual(UpdateRule.compareVersions("0.10.0", "0.9.0"), 1)
        XCTAssertEqual(UpdateRule.compareVersions("1.0.0", "1.0.0"), 0)
        XCTAssertEqual(UpdateRule.compareVersions("99999999999999999999.0.0", "99999999999999999998.0.0"), 1)
        XCTAssertEqual(UpdateRule.compareNumbers("007", "7"), 0)
    }

    // MARK: Offline and cache states

    func testOfflineTheCachedCopyIsListedWithItsWarning() async throws {
        let (model, _) = model([try loaded("catalog-valid-live-only", warning: "Could not fetch the catalog; showing the copy cached 2 hours ago.")])
        await model.refresh()
        XCTAssertEqual(model.status, .offline("Could not fetch the catalog; showing the copy cached 2 hours ago."))
        XCTAssertEqual(model.rows.map(\.id), ["breaks"])
    }

    func testWithNothingCachedTheErrorIsShownAndNothingListed() async {
        let (model, _) = model([.failure(.unavailable("Could not fetch the catalog, and there is no cached copy."))])
        XCTAssertEqual(model.status, .loading)
        XCTAssertEqual(model.updatesMenuTitle, "Checking for updates…")
        await model.refresh()
        XCTAssertEqual(model.status, .failed("Could not fetch the catalog, and there is no cached copy."))
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.updatesMenuTitle, "Updates unavailable")
    }

    func testAFailedRefreshKeepsTheListForSevenDays() async throws {
        try install("Breaks", "dev.subset.breaks", version: "0.0.9")
        let (model, _) = model([
            try loaded("catalog-valid-live-only"), .failure(.invalid("The catalog is not a valid subset.catalog@1 feed")),
            .failure(.unavailable("offline"))
        ])
        await model.refresh()
        clock.advance(6 * 24 * 60 * 60)
        await model.refresh()
        XCTAssertEqual(model.status, .failed("The catalog is not a valid subset.catalog@1 feed"))
        XCTAssertEqual(model.rows.map(\.id), ["breaks"])
        XCTAssertEqual(model.updatesMenuTitle, "1 update available")
        clock.advance(24 * 60 * 60)
        await model.refresh()
        XCTAssertEqual(model.status, .failed("offline"))
        XCTAssertNil(model.catalog)
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.updatesMenuTitle, "Updates unavailable")
    }

    func testACancelledRefreshChangesNothing() async throws {
        let loader = GatedLoader()
        let feed = try loaded("catalog-valid-live-only")
        let clock = clock
        let model = AppListModel(loader: loader, finder: finder, defaults: defaults, now: { clock.now })
        let first = Task { await model.refresh() }
        try await waitUntil({ loader.isWaiting }, stopping: first, release: { loader.close() })
        loader.finish(feed)
        await first.value
        let fetchedAt = model.fetchedAt
        XCTAssertEqual(model.status, .current)

        // The test cancels its own refresh task mid-fetch, as stopAutoRefresh would;
        // the transport then reports the fetch as cancelled.
        clock.advance(60 * 60)
        let cancelled = Task { await model.refresh() }
        try await waitUntil({ loader.isWaiting }, stopping: cancelled, release: { loader.close() })
        cancelled.cancel()
        loader.finish(.failure(.unavailable("Could not fetch the catalog (cancelled), and there is no cached copy.")))
        await cancelled.value
        XCTAssertEqual(model.status, .current)
        XCTAssertEqual(model.fetchedAt, fetchedAt)
        XCTAssertEqual(model.rows.map(\.id), ["breaks"])
        XCTAssertFalse(model.isRefreshing)
    }

    func testARefreshCancelledDuringDetectionChangesNothing() async throws {
        try install("Breaks", "dev.subset.breaks", version: "0.0.9")
        // Every look is published (for the apps of the catalog shown); this one reads what is installed.
        let gated = GatedFinder(finder, gatedCalls: [2], readsAfterGate: true)
        let first = try loaded("catalog-valid-live-only")
        clock.advance(60 * 60)
        // The next load succeeds with another feed, then the refresh is cancelled while the apps are detected.
        let second = try loaded("catalog-valid-live-and-beta", warning: "offline")
        let loader = RecordedLoader([first, second])
        let clock = clock
        let model = AppListModel(loader: loader, finder: gated, defaults: defaults, now: { clock.now })
        await model.refresh()
        let catalog = model.catalog
        let fetchedAt = model.fetchedAt
        let installed = model.installed
        XCTAssertEqual(model.status, .current)
        XCTAssertEqual(installed["breaks"]?.map(\.versionLabel), ["0.0.9"])

        let cancelled = Task { await model.refresh() }
        // The gated detection is on a detached task; on a timeout the release lets it end if it starts later.
        try await waitUntil({ gated.isWaiting }, stopping: cancelled, release: { gated.release() })
        cancelled.cancel()
        gated.release()
        await cancelled.value
        XCTAssertEqual(model.catalog, catalog)
        XCTAssertEqual(model.fetchedAt, fetchedAt)
        XCTAssertEqual(model.status, .current)
        XCTAssertEqual(model.installed, installed)
        XCTAssertEqual(model.updatesMenuTitle, "1 update available")
        XCTAssertFalse(model.isRefreshing)
    }

    /// Waits until `condition` holds. When it does not within `timeout` seconds, it records a failure, stops `task` (see
    /// `stop`) and throws, so the test stops there and no refresh is left running, or publishing, when tearDown removes
    /// the defaults suite and the temporary folder.
    private func waitUntil(
        timeout: TimeInterval = 5, _ condition: () -> Bool, stopping task: Task<Void, Never>, release: () -> Void
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out")
                if await !stop(task, release: release) {
                    XCTFail("the refresh did not end within 2 seconds of being stopped")
                }
                throw WaitTimedOut()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Cancels `task` first, so the refresh publishes nothing, then runs `release` to let go of whatever it waits on,
    /// then waits up to `limit` for it to end. Returns whether it ended in time.
    private func stop(_ task: Task<Void, Never>, release: () -> Void, within limit: Duration = .seconds(2)) async -> Bool {
        task.cancel()
        release()
        return await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            Task { await task.value; answer.give(true) }
            Task { try? await Task.sleep(for: limit); answer.give(false) }
        }
    }

    /// Forces a wait to time out while `task` is held, and checks that it failed with "timed out", threw, and stopped
    /// the task promptly.
    private func forceATimedOutWait(stopping task: Task<Void, Never>, release: () -> Void) async {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("timed out") }
        XCTExpectFailure("the condition never holds", options: options)
        let started = Date()
        do {
            try await waitUntil(timeout: 0.1, { false }, stopping: task, release: release)
            XCTFail("the wait did not throw")
        } catch {
            XCTAssert(error is WaitTimedOut, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testATimedOutWaitDuringTheLoadStopsTheRefreshAndChangesNothing() async throws {
        try install("Breaks", "dev.subset.breaks", version: "0.0.9")
        let loader = GatedLoader()
        loader.finish(try loaded("catalog-valid-live-only"))
        let clock = clock
        let model = AppListModel(loader: loader, finder: finder, defaults: defaults, now: { clock.now })
        await model.refresh()
        let (catalog, fetchedAt, installed) = (model.catalog, model.fetchedAt, model.installed)
        XCTAssertEqual(model.status, .current)
        XCTAssertEqual(installed["breaks"]?.map(\.versionLabel), ["0.0.9"])

        clock.advance(60 * 60)
        let refresh = Task { await model.refresh() }
        try await waitUntil({ loader.isWaiting }, stopping: refresh, release: { loader.close() })
        await forceATimedOutWait(stopping: refresh, release: { loader.close() })
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.catalog, catalog)
        XCTAssertEqual(model.status, .current)
        XCTAssertEqual(model.fetchedAt, fetchedAt)
        XCTAssertEqual(model.installed, installed)
    }

    func testATimedOutWaitDuringDetectionStopsTheRefreshAndChangesNothing() async throws {
        try install("Breaks", "dev.subset.breaks", version: "0.0.9")
        // Every look is published (for the apps of the catalog shown); this one reads what is installed.
        let gated = GatedFinder(finder, gatedCalls: [2], readsAfterGate: true)
        let first = try loaded("catalog-valid-live-only")
        clock.advance(60 * 60)
        let second = try loaded("catalog-valid-live-and-beta", warning: "offline")
        let clock = clock
        let model = AppListModel(loader: RecordedLoader([first, second]), finder: gated, defaults: defaults, now: { clock.now })
        await model.refresh()
        let (catalog, fetchedAt, installed) = (model.catalog, model.fetchedAt, model.installed)
        XCTAssertEqual(model.status, .current)
        XCTAssertEqual(installed["breaks"]?.map(\.versionLabel), ["0.0.9"])

        let refresh = Task { await model.refresh() }
        try await waitUntil({ gated.isWaiting }, stopping: refresh, release: { gated.release() })
        await forceATimedOutWait(stopping: refresh, release: { gated.release() })
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.catalog, catalog)
        XCTAssertEqual(model.status, .current)
        XCTAssertEqual(model.fetchedAt, fetchedAt)
        XCTAssertEqual(model.installed, installed)
    }

    func testAResultFinishedBeforeTheLoadArrivesIsKeptForIt() async throws {
        let loader = GatedLoader()
        loader.finish(try loaded("catalog-valid-live-only"))
        let clock = clock
        let model = AppListModel(loader: loader, finder: finder, defaults: defaults, now: { clock.now })
        await model.refresh()
        XCTAssertEqual(model.status, .current)
        XCTAssertEqual(model.rows.map(\.id), ["breaks"])
    }

    func testInstalledAppsAreLookedForAgainOnEachRefresh() async throws {
        let (model, _) = model([try loaded("catalog-valid-live-only"), try loaded("catalog-valid-live-only")])
        await model.refresh()
        XCTAssertEqual(model.rows[0].installed, [])
        try install("Breaks", "dev.subset.breaks", version: "0.0.9")
        await model.refresh()
        XCTAssertEqual(model.rows[0].installed.map(\.versionLabel), ["0.0.9"])
    }

    // MARK: Refresh schedule

    func testAutoRefreshLoadsAtOnceAndThenEveryInterval() async throws {
        let (model, loader) = model(Array(repeating: try loaded("catalog-valid-live-only"), count: 10))
        XCTAssertTrue(model.startAutoRefresh(every: .milliseconds(50)))
        XCTAssertTrue(model.startAutoRefresh(every: .milliseconds(50)))
        let deadline = Date().addingTimeInterval(5)
        while loader.loads < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.stopAutoRefresh()
        XCTAssertGreaterThanOrEqual(loader.loads, 3)
        XCTAssertNotNil(model.catalog)
        XCTAssertEqual(AppListModel.refreshInterval, .seconds(6 * 60 * 60))
    }

    func testAZeroOrNegativeIntervalIsRefusedAndStartsNothing() async throws {
        let (model, loader) = model(Array(repeating: try loaded("catalog-valid-live-only"), count: 10))
        XCTAssertFalse(model.startAutoRefresh(every: .zero))
        XCTAssertFalse(model.startAutoRefresh(every: .seconds(-1)))
        XCTAssertFalse(model.startAutoRefresh(every: .milliseconds(-50)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loader.loads, 0, "a refused interval refreshes nothing")
        XCTAssertNil(model.catalog)
        // A refused start leaves nothing running, so a positive interval still starts.
        XCTAssertTrue(model.startAutoRefresh(every: .seconds(60)))
        let deadline = Date().addingTimeInterval(5)
        while loader.loads < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.stopAutoRefresh()
        XCTAssertEqual(loader.loads, 1)
    }

    // Looks for installed apps run one after another, so the last to publish is the latest look at every app, whether
    // the earlier look was held before it read the folders or after it had read them: an app the subset command
    // installs meanwhile is listed either way.
    func testAnAppInstalledWhileAnEarlierLookIsHeldIsListed() async throws {
        for readsAfterGate in [true, false] {
            let gated = GatedFinder(finder, gatedCalls: [2], readsAfterGate: readsAfterGate)
            let model = AppListModel(loader: RecordedLoader([try loaded("catalog-valid-live-only")]), finder: gated, defaults: defaults)
            await model.refresh()
            let earlier = Task { _ = await model.reloadInstalled() }
            try await waitUntil({ gated.isWaiting }, stopping: earlier, release: { gated.release() })
            let later = Task { _ = await model.reloadInstalled() }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(gated.callCount, 2, "the later look waits for the earlier one")
            try install("Breaks", "dev.subset.breaks", version: "0.1.0")
            gated.release()
            await earlier.value
            await later.value
            XCTAssertEqual(model.installed["breaks"]?.map(\.versionLabel), ["0.1.0"], "held \(readsAfterGate ? "before" : "after") reading")
            try FileManager.default.removeItem(at: root.appendingPathComponent("apps/Breaks.app"))
        }
    }

    // Looks asked for while one is held up (a stalled folder) are merged into one look begun after it ends, whoever
    // asks (reloads after operations, a manual refresh, the auto-refresh loop): never two detect() calls at once, never
    // more than one waiting, and the held look runs on a queue of its own, so other async work goes on meanwhile.
    func testLooksAskedForDuringAHeldLookAreOneLookBegunAfterIt() async throws {
        let counting = InFlightFinder(finder, gated: 2)
        let model = AppListModel(loader: RecordedLoader(Array(repeating: try loaded("catalog-valid-live-only"), count: 50)), finder: counting, defaults: defaults)
        await model.refresh()
        var reloads: [Task<Void, Never>] = []
        reloads.append(Task { await model.reloadInstalled() })
        let deadline = Date().addingTimeInterval(5)
        while !counting.isHolding, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(counting.isHolding)
        for _ in 0..<20 { reloads.append(Task { await model.reloadInstalled() }) }
        let refresh = Task { await model.refresh(force: true) }
        XCTAssertTrue(model.startAutoRefresh(every: .milliseconds(20)))
        // 64 tasks on Swift's shared pool, each sleeping and yielding, finish while the look stays held.
        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    for _ in 0..<5 {
                        try? await Task.sleep(for: .milliseconds(2))
                        await Task.yield()
                    }
                }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "other async work is not held up by the held look")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counting.callCount, 2, "nothing else is looked for while the look is held")
        try install("Breaks", "dev.subset.breaks", version: "0.1.0")
        counting.release()
        for reload in reloads { await reload.value }
        await refresh.value
        model.stopAutoRefresh()
        XCTAssertEqual(counting.peak, 1, "one detect() at a time")
        XCTAssertEqual(model.installed["breaks"]?.map(\.versionLabel), ["0.1.0"], "the merged look, begun after the held one, is shown")
    }

    // A refresh's look is held, having read before the subset command installs the app, while a reload is asked for:
    // the looks are published in the order they began, so the held one (nothing installed) comes first and the reload's
    // (the install) last, whichever caller is awaited first; what is shown never goes back to an older state.
    func testLooksArePublishedInTheOrderTheyBeganWhicheverCallerEndsFirst() async throws {
        for refreshFirst in [true, false] {
            let gated = GatedFinder(finder, gatedCalls: [2], readsAfterGate: false)
            let model = AppListModel(loader: RecordedLoader([try loaded("catalog-valid-live-only"), try loaded("catalog-valid-live-only")]), finder: gated, defaults: defaults)
            await model.refresh()
            let shown = Recorder<[[String]]>([])
            let watching = model.$installed.sink { installed in shown.update { $0.append(installed["breaks"]?.map(\.versionLabel) ?? []) } }
            let refresh = Task { await model.refresh(force: true) }
            try await waitUntil({ gated.isWaiting }, stopping: refresh, release: { gated.release() })
            let reload = Task { await model.reloadInstalled() }
            try install("Breaks", "dev.subset.breaks", version: "0.1.0")
            gated.release()
            if refreshFirst {
                await refresh.value
                await reload.value
            } else {
                await reload.value
                await refresh.value
            }
            watching.cancel()
            XCTAssertEqual(model.installed["breaks"]?.map(\.versionLabel), ["0.1.0"], "refresh awaited first: \(refreshFirst)")
            XCTAssertEqual(shown.get().last, ["0.1.0"])
            XCTAssertEqual(shown.get().drop { $0 != ["0.1.0"] }.filter { $0 != ["0.1.0"] }, [], "never back to an older state: \(shown.get())")
            XCTAssertEqual(gated.callCount, 3)
            try FileManager.default.removeItem(at: root.appendingPathComponent("apps/Breaks.app"))
        }
    }

    // A refresh to a feed that describes an app differently (another app name) and a reload over the old feed are both
    // asked for while a look is held, in either order: the merged look covers both descriptions, so the new feed is
    // shown with what is installed as it describes the app, and the reload ends with the old description looked at.
    func testLooksMergedAcrossFeedsCoverEachDescriptionOfAnApp() async throws {
        for refreshFirst in [true, false] {
            try install("Breaks", "dev.subset.breaks", version: "0.0.9")
            try install("Breaks Renamed", "dev.subset.breaks", version: "0.1.0")
            var renamed = AppInstallerTests.breaks
            renamed.appName = "Breaks Renamed"
            let url = CatalogLocation.defaultURL
            let old = LoadedCatalog(catalog: Catalog(generatedAt: "2026-11-12T00:00:00Z", apps: [AppInstallerTests.breaks], tools: []), url: url, fetchedAt: clock.now, cached: false)
            let new = LoadedCatalog(catalog: Catalog(generatedAt: "2026-11-13T00:00:00Z", apps: [renamed], tools: []), url: url, fetchedAt: clock.now, cached: false)
            let counting = InFlightFinder(finder, gated: 2)
            let model = AppListModel(loader: RecordedLoader([.success(old), .success(new)]), finder: counting, defaults: defaults)
            await model.refresh()
            XCTAssertEqual(model.installed["breaks"]?.map(\.versionLabel), ["0.0.9"])
            let held = Task { await model.reloadInstalled() }
            let deadline = Date().addingTimeInterval(5)
            while !counting.isHolding, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            var refresh: Task<Void, Never>?
            var reload: Task<Void, Never>?
            if refreshFirst {
                refresh = Task { await model.refresh(force: true) }
                try await Task.sleep(for: .milliseconds(50))
                reload = Task { await model.reloadInstalled() }
            } else {
                reload = Task { await model.reloadInstalled() }
                try await Task.sleep(for: .milliseconds(50))
                refresh = Task { await model.refresh(force: true) }
            }
            try await Task.sleep(for: .milliseconds(50))
            counting.release()
            await held.value
            await reload?.value
            await refresh?.value
            XCTAssertEqual(model.catalog?.apps.map(\.appName), ["Breaks Renamed"], "refresh first: \(refreshFirst)")
            XCTAssertEqual(model.installed["breaks"]?.map(\.versionLabel), ["0.1.0"], "refresh first: \(refreshFirst): the new description's copy")
            XCTAssertEqual(counting.peak, 1)
            for name in ["Breaks", "Breaks Renamed"] { try FileManager.default.removeItem(at: root.appendingPathComponent("apps/\(name).app")) }
        }
    }

    // A look that never ends (a folder that stays stalled) does not freeze the list: it is given up after `scanStall`
    // and the next look begins, so a reload still ends with a look begun after it; a refresh shows its catalog after
    // `refreshWait` at most; a cancelled refresh ends at once; and at most `maxStalled` given-up looks hold a thread.
    func testALookThatNeverEndsDoesNotFreezeTheList() async throws {
        let stuck = GatedFinder(finder, gatedCalls: [2])
        let model = AppListModel(loader: RecordedLoader(Array(repeating: try loaded("catalog-valid-live-only"), count: 5)), finder: stuck, defaults: defaults)
        model.scanStall = .milliseconds(200)
        model.refreshWait = .milliseconds(400)
        await model.refresh()
        let reload = Task { await model.reloadInstalled() }
        try await waitUntil({ stuck.isWaiting }, stopping: reload, release: { stuck.release() })
        try install("Breaks", "dev.subset.breaks", version: "0.1.0")
        await reload.value
        XCTAssertEqual(model.installed["breaks"]?.map(\.versionLabel), ["0.1.0"], "the look begun after the stalled one is shown")
        XCTAssertEqual(stuck.holding, 1, "the stalled look still holds its thread")
        stuck.release()

        // Every look stalls: the refresh still ends (bounded), a cancelled one ends at once, no more than 1 + maxStalled
        // looks ever hold a thread, and what was shown stays known.
        let allStuck = InFlightFinder(finder, gated: 2, holdingFrom: true)
        let stalled = AppListModel(loader: RecordedLoader(Array(repeating: try loaded("catalog-valid-live-only"), count: 5)), finder: allStuck, defaults: defaults)
        stalled.scanStall = .milliseconds(100)
        stalled.refreshWait = .milliseconds(300)
        await stalled.refresh()
        let started = Date()
        await stalled.refresh(force: true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the refresh ended")
        XCTAssertFalse(stalled.isRefreshing)
        XCTAssertEqual(stalled.status, .current)
        XCTAssertTrue(stalled.knowsInstalled("breaks"), "the earlier look of the same description stays shown")
        let cancelled = Task { await stalled.refresh(force: true) }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = Date()
        cancelled.cancel()
        await cancelled.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.2, "a cancelled refresh ends at once")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThanOrEqual(allStuck.peak, 1 + stalled.maxStalled, "bounded threads")
        allStuck.releaseAll()
    }

    // An app the catalog drops and later lists again is not known from a look made before it was dropped: when the
    // look of the catalog listing it again is held past `refreshWait`, its actions wait for a look of their own.
    func testAnAppListedAgainNeedsALookOfItsOwn() async throws {
        var other = AppInstallerTests.breaks
        (other.id, other.name, other.appName, other.bundleID) = ("other", "Other", "Other", "dev.subset.other")
        let url = CatalogLocation.defaultURL
        let withBreaks = LoadedCatalog(catalog: Catalog(generatedAt: "2026-11-12T00:00:00Z", apps: [AppInstallerTests.breaks], tools: []), url: url, fetchedAt: clock.now, cached: false)
        let without = LoadedCatalog(catalog: Catalog(generatedAt: "2026-11-13T00:00:00Z", apps: [other], tools: []), url: url, fetchedAt: clock.now, cached: false)
        let stuck = GatedFinder(finder, gatedCalls: [3])
        let model = AppListModel(loader: RecordedLoader([.success(withBreaks), .success(without), .success(withBreaks)]), finder: stuck, defaults: defaults)
        model.scanStall = .seconds(30)
        model.refreshWait = .milliseconds(200)
        await model.refresh()
        XCTAssertTrue(model.knowsInstalled("breaks"))
        await model.refresh(force: true)
        XCTAssertFalse(model.knowsInstalled("breaks"), "not listed")
        try install("Breaks", "dev.subset.breaks", version: "0.1.0")
        await model.refresh(force: true)
        XCTAssertEqual(model.catalog?.apps.map(\.id), ["breaks"])
        XCTAssertFalse(model.knowsInstalled("breaks"), "the look from before it was dropped does not count")
        XCTAssertNil(model.installed["breaks"])
        stuck.release()
    }

    // An operation's reload waits while a refresh changes how the catalog describes the app: it ends only once the
    // description now shown has a look begun after the reload, not with a look of the old description.
    func testAReloadEndsWithALookOfTheDescriptionShownNow() async throws {
        var renamed = AppInstallerTests.breaks
        renamed.appName = "Breaks Renamed"
        let url = CatalogLocation.defaultURL
        let old = LoadedCatalog(catalog: Catalog(generatedAt: "2026-11-12T00:00:00Z", apps: [AppInstallerTests.breaks], tools: []), url: url, fetchedAt: clock.now, cached: false)
        let new = LoadedCatalog(catalog: Catalog(generatedAt: "2026-11-13T00:00:00Z", apps: [renamed], tools: []), url: url, fetchedAt: clock.now, cached: false)
        // The refresh's look (call 2) has read before the install and is held.
        let gated = GatedFinder(finder, gatedCalls: [2], readsAfterGate: false)
        let model = AppListModel(loader: RecordedLoader([.success(old), .success(new)]), finder: gated, defaults: defaults)
        await model.refresh()
        let refresh = Task { await model.refresh(force: true) }
        try await waitUntil({ gated.isWaiting }, stopping: refresh, release: { gated.release() })
        let reload = Task { await model.reloadInstalled() }
        try install("Breaks Renamed", "dev.subset.breaks", version: "0.1.0")
        gated.release()
        await refresh.value
        await reload.value
        XCTAssertEqual(model.catalog?.apps.map(\.appName), ["Breaks Renamed"])
        XCTAssertEqual(model.installed["breaks"]?.map(\.versionLabel), ["0.1.0"], "the reload ended with a look of the description shown")
    }

    // A refresh with a new feed and a reload over the old feed: the list shows the new feed with what is installed for it.
    func testARefreshWithANewFeedAndAReloadOverTheOldOneListTheNewFeedsApps() async throws {
        try install("Breaks", "dev.subset.breaks", version: "0.0.9")
        try install("Other", "dev.subset.other", version: "1.0.0")
        let breaks = AppInstallerTests.breaks
        var other = breaks
        (other.id, other.name, other.appName, other.bundleID) = ("other", "Other", "Other", "dev.subset.other")
        let url = CatalogLocation.defaultURL
        let old = LoadedCatalog(catalog: Catalog(generatedAt: "2026-11-12T00:00:00Z", apps: [breaks], tools: []), url: url, fetchedAt: clock.now, cached: false)
        let new = LoadedCatalog(catalog: Catalog(generatedAt: "2026-11-13T00:00:00Z", apps: [breaks, other], tools: []), url: url, fetchedAt: clock.now, cached: false)
        let gated = GatedFinder(finder, gatedCalls: [2], readsAfterGate: true)
        let model = AppListModel(loader: RecordedLoader([.success(old), .success(new)]), finder: gated, defaults: defaults)
        await model.refresh()
        let refresh = Task { await model.refresh(force: true) }
        try await waitUntil({ gated.isWaiting }, stopping: refresh, release: { gated.release() })
        let reload = Task { _ = await model.reloadInstalled() }
        // An operation updates Breaks while the refresh's look is held.
        try install("Breaks", "dev.subset.breaks", version: "0.1.0")
        gated.release()
        await refresh.value
        await reload.value
        XCTAssertEqual(model.catalog?.apps.map(\.id), ["breaks", "other"])
        XCTAssertEqual(model.installed["other"]?.map(\.versionLabel), ["1.0.0"])
        XCTAssertEqual(model.installed["breaks"]?.map(\.versionLabel), ["0.1.0"])
    }
}

/// Counts the detect() calls in flight; call `gated` (from 1) waits until `release`.
final class InFlightFinder: InstalledAppDetecting, @unchecked Sendable {
    private let finder: InstalledAppFinder
    private let gated: Int
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var inFlight = 0
    private var mostInFlight = 0

    /// With `holdingFrom`, every call from `gated` on waits (until `releaseAll`).
    private let holdingFrom: Bool
    private var released = false

    init(_ finder: InstalledAppFinder, gated: Int, holdingFrom: Bool = false) {
        self.finder = finder
        self.gated = gated
        self.holdingFrom = holdingFrom
    }

    var callCount: Int { lock.withLock { calls } }
    /// The most detect() calls ever in flight at once.
    var peak: Int { lock.withLock { mostInFlight } }
    var isHolding: Bool { lock.withLock { inFlight > 0 && calls == gated } }

    func detect(_ apps: [CatalogApp]) -> [String: [InstalledCopy]] {
        let call = lock.withLock { () -> Int in
            calls += 1
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            return calls
        }
        defer { lock.withLock { inFlight -= 1 } }
        if call == gated || (holdingFrom && call > gated && !lock.withLock({ released })) { gate.wait() }
        return finder.detect(apps)
    }

    func release() { gate.signal() }

    /// Lets every held call, and every later one, go.
    func releaseAll() {
        let held = lock.withLock { () -> Int in
            released = true
            return inFlight
        }
        for _ in 0..<held { gate.signal() }
    }
}
