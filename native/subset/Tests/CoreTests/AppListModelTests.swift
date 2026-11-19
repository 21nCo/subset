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

/// Detects with `finder`, except that call numbers `gatedCalls` (from 1) wait until `release`, then find nothing.
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
        let gated = GatedFinder(finder, gatedCall: 2)
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
        let gated = GatedFinder(finder, gatedCall: 2)
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
            let earlier = Task { await model.reloadInstalled() }
            try await waitUntil({ gated.isWaiting }, stopping: earlier, release: { gated.release() })
            let later = Task { await model.reloadInstalled() }
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
        let reload = Task { await model.reloadInstalled() }
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
