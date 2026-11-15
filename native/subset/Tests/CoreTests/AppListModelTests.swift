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

/// Holds each load until the test finishes it, so a test can act while a fetch is in flight.
final class GatedLoader: CatalogLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Result<LoadedCatalog, CatalogError>, Never>?

    var isWaiting: Bool { lock.withLock { waiting != nil } }

    func load(refresh _: Bool) async -> Result<LoadedCatalog, CatalogError> {
        await withCheckedContinuation { continuation in lock.withLock { waiting = continuation } }
    }

    func finish(_ result: Result<LoadedCatalog, CatalogError>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Result<LoadedCatalog, CatalogError>, Never>? in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(returning: result)
    }
}

/// Detects with `finder`, except that call number `gatedCall` (from 1) waits until `release`, then finds nothing.
final class GatedFinder: InstalledAppDetecting, @unchecked Sendable {
    private let finder: InstalledAppFinder
    private let gatedCall: Int
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var waiting = false

    init(_ finder: InstalledAppFinder, gatedCall: Int) {
        self.finder = finder
        self.gatedCall = gatedCall
    }

    var isWaiting: Bool { lock.withLock { waiting } }

    func detect(_ apps: [CatalogApp]) -> [String: [InstalledCopy]] {
        let call = lock.withLock { () -> Int in
            calls += 1
            if calls == gatedCall { waiting = true }
            return calls
        }
        guard call == gatedCall else { return finder.detect(apps) }
        gate.wait()
        return [:]
    }

    func release() { gate.signal() }
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
        XCTAssertNil(AppListModel.offeredUpdate(app, [beta], showBetas: false))
        XCTAssertEqual(AppListModel.offeredUpdate(app, [beta], showBetas: true), "0.1.1-beta.4")
        XCTAssertNil(AppListModel.offeredUpdate(app, [noReceipt], showBetas: true), "without a receipt builds are not compared")
        var released = app
        released.live?.version = "0.1.1"
        XCTAssertEqual(AppListModel.offeredUpdate(released, [beta], showBetas: false), "0.1.1")
        XCTAssertEqual(AppListModel.offeredUpdate(released, [beta], showBetas: true), "0.1.1", "a release is newer than its betas")
        XCTAssertNil(AppListModel.offeredUpdate(released, [noReceipt], showBetas: true))
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
        let clock = clock
        let model = AppListModel(loader: loader, finder: finder, defaults: defaults, now: { clock.now })
        let first = Task { await model.refresh() }
        try await waitUntil { loader.isWaiting }
        loader.finish(try loaded("catalog-valid-live-only"))
        await first.value
        let fetchedAt = model.fetchedAt
        XCTAssertEqual(model.status, .current)

        // The test cancels its own refresh task mid-fetch, as stopAutoRefresh would;
        // the transport then reports the fetch as cancelled.
        clock.advance(60 * 60)
        let cancelled = Task { await model.refresh() }
        try await waitUntil { loader.isWaiting }
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
        try await waitUntil { gated.isWaiting }
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

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
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
        model.startAutoRefresh(every: .milliseconds(50))
        model.startAutoRefresh(every: .milliseconds(50))
        let deadline = Date().addingTimeInterval(5)
        while loader.loads < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.stopAutoRefresh()
        XCTAssertGreaterThanOrEqual(loader.loads, 3)
        XCTAssertNotNil(model.catalog)
        XCTAssertEqual(AppListModel.refreshInterval, .seconds(6 * 60 * 60))
    }
}
