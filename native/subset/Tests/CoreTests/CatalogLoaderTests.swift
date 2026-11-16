import Foundation
@testable import SubsetCore
import XCTest

/// Answers each fetch with the next recorded response: the bytes of a fixture, or a FeedUnavailable.
final class RecordedTransport: FeedTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<Data, FeedUnavailable>]
    private(set) var fetches = 0

    init(_ responses: [Result<Data, FeedUnavailable>]) {
        self.responses = responses
    }

    func fetch(_: URL, limit _: Int) async throws -> Data {
        try lock.withLock {
            fetches += 1
            guard !responses.isEmpty else { throw FeedUnavailable("no recorded response") }
            return try responses.removeFirst().get()
        }
    }
}

/// A clock the tests move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ interval: TimeInterval) {
        lock.withLock { current += interval }
    }
}

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: CatalogFeedTests.feedFolder.appendingPathComponent("fixtures/\(name).json"))
}

final class CatalogLoaderTests: XCTestCase {
    private var folder: URL!
    private let clock = TestClock()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-cache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var cacheFile: URL { folder.appendingPathComponent("Subset/catalog.json") }

    private func loader(_ transport: RecordedTransport, url: URL = CatalogLocation.defaultURL) -> CatalogLoader {
        let clock = clock
        return CatalogLoader(location: .success(url), cacheFile: cacheFile, transport: transport, now: { clock.now })
    }

    // MARK: Where the feed is

    func testTheDefaultFeedIsUsedUnlessOverridden() {
        XCTAssertEqual(try CatalogLocation.resolve(environment: [:], defaultsValue: nil).get().absoluteString,
                       "https://subset.21n.dev/catalog/v1.json")
        XCTAssertEqual(try CatalogLocation.resolve(environment: ["SUBSET_CATALOG_URL": ""], defaultsValue: "").get(),
                       CatalogLocation.defaultURL)
    }

    func testTheEnvironmentWinsOverTheHiddenDefault() throws {
        let env = try CatalogLocation.resolve(
            environment: ["SUBSET_CATALOG_URL": "https://subset.21n.dev/catalog/env.json"],
            defaultsValue: "https://subset.21n.dev/catalog/defaults.json"
        ).get()
        XCTAssertEqual(env.path, "/catalog/env.json")
        let defaults = try CatalogLocation.resolve(environment: [:], defaultsValue: "https://SUBSET.21n.dev/catalog/defaults.json").get()
        XCTAssertEqual(defaults.path, "/catalog/defaults.json")
    }

    func testAnAcceptedURLIsSpelledAsSubsetSpellsIt() throws {
        // subset keys the shared cache by WHATWG url.href; the same feed must get the same key here.
        let spellings = [
            ("HTTPS://SUBSET.21n.DEV/catalog/v1.json", "https://subset.21n.dev/catalog/v1.json"),
            ("https://subset.21n.dev:443/catalog/v1.json", "https://subset.21n.dev/catalog/v1.json"),
            ("https://Subset.21n.dev", "https://subset.21n.dev/"),
            ("https://subset.21n.dev?v=2", "https://subset.21n.dev/?v=2"),
            ("https://subset.21n.dev:8443/Catalog/V1.json", "https://subset.21n.dev:8443/Catalog/V1.json")
        ]
        for (text, href) in spellings {
            let url = try CatalogLocation.resolve(environment: ["SUBSET_CATALOG_URL": text], defaultsValue: nil).get()
            XCTAssertEqual(url.absoluteString, href, text)
        }
    }

    func testOnlyHTTPSURLsOnAnAllowedHostAreAccepted() {
        let refused = [
            ("http://subset.21n.dev/catalog/v1.json", "must be an https URL"),
            ("file:///tmp/catalog.json", "must be an https URL"),
            ("https://example.com/catalog/v1.json", "names the host example.com, which is not one of subset.21n.dev"),
            ("https://subset.21n.dev.example.com/v1.json", "which is not one of"),
            ("https://user:secret@subset.21n.dev/catalog/v1.json", "must not contain a user name or password"),
            ("not a url", "is not a URL")
        ]
        for (text, reason) in refused {
            guard case .failure(.invalid(let message)) = CatalogLocation.resolve(environment: ["SUBSET_CATALOG_URL": text], defaultsValue: nil) else {
                XCTFail("\(text) is accepted")
                continue
            }
            XCTAssertTrue(message.hasPrefix("SUBSET_CATALOG_URL"), message)
            XCTAssertTrue(message.contains(reason), "\(message) lacks \(reason)")
        }
        guard case .failure(.invalid(let message)) = CatalogLocation.resolve(environment: [:], defaultsValue: "http://subset.21n.dev/") else {
            return XCTFail("an http default is accepted")
        }
        XCTAssertTrue(message.hasPrefix("The SubsetCatalogURL default"), message)
    }

    func testARefusedLocationIsReportedWithoutFetching() async {
        let transport = RecordedTransport([.success(try! fixture("catalog-valid-live-only"))])
        let loader = CatalogLoader(
            location: .failure(.invalid("SUBSET_CATALOG_URL must be an https URL, not http:")), cacheFile: cacheFile,
            transport: transport
        )
        let result = await loader.load(refresh: false)
        XCTAssertEqual(result, .failure(.invalid("SUBSET_CATALOG_URL must be an https URL, not http:")))
        XCTAssertEqual(transport.fetches, 0)
    }

    // MARK: Cache

    func testAFetchedFeedIsCachedForFiveMinutes() async throws {
        let transport = RecordedTransport([.success(try fixture("catalog-valid-live-only")), .success(try fixture("catalog-valid-live-and-beta"))])
        let loader = loader(transport)
        let first = try await loader.load(refresh: false).get()
        XCTAssertFalse(first.cached)
        XCTAssertEqual(first.catalog.apps.map(\.id), ["breaks"])
        clock.advance(4 * 60)
        let second = try await loader.load(refresh: false).get()
        XCTAssertTrue(second.cached)
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        XCTAssertEqual(transport.fetches, 1)
        clock.advance(61)
        let third = try await loader.load(refresh: false).get()
        XCTAssertFalse(third.cached)
        XCTAssertEqual(third.catalog.apps.map(\.id), ["breaks", "timer"])
        XCTAssertEqual(transport.fetches, 2)
    }

    func testRefreshFetchesEvenWhenTheCacheIsFresh() async throws {
        let transport = RecordedTransport([.success(try fixture("catalog-valid-live-only")), .success(try fixture("catalog-valid-live-and-beta"))])
        let loader = loader(transport)
        _ = try await loader.load(refresh: false).get()
        let refreshed = try await loader.load(refresh: true).get()
        XCTAssertFalse(refreshed.cached)
        XCTAssertEqual(transport.fetches, 2)
    }

    func testAForcedRefreshThatCannotFetchIsAnErrorEvenWithAFreshCache() async throws {
        let transport = RecordedTransport([.success(try fixture("catalog-valid-live-only")), .failure(FeedUnavailable("HTTP 503"))])
        let loader = loader(transport)
        _ = try await loader.load(refresh: false).get()
        let refreshed = await loader.load(refresh: true)
        XCTAssertEqual(refreshed, .failure(.unavailable(
            "Could not fetch the catalog from https://subset.21n.dev/catalog/v1.json (HTTP 503)."
        )))
    }

    func testOfflineACopyCachedLessThanSevenDaysAgoIsUsedWithAWarning() async throws {
        let transport = RecordedTransport([.success(try fixture("catalog-valid-live-only")), .failure(FeedUnavailable("not connected to the internet"))])
        let loader = loader(transport)
        let fetched = try await loader.load(refresh: false).get()
        clock.advance(3 * 60 * 60)
        let offline = try await loader.load(refresh: false).get()
        XCTAssertTrue(offline.cached)
        XCTAssertEqual(offline.fetchedAt, fetched.fetchedAt)
        XCTAssertEqual(offline.catalog, fetched.catalog)
        XCTAssertEqual(
            offline.warning,
            "Could not fetch the catalog from https://subset.21n.dev/catalog/v1.json (not connected to the internet); showing the copy cached 3 hours ago."
        )
    }

    func testOfflineACopyCachedSevenDaysAgoOrNoCopyIsAnError() async throws {
        let transport = RecordedTransport([
            .failure(FeedUnavailable("HTTP 503")), .success(try fixture("catalog-valid-live-only")), .failure(FeedUnavailable("HTTP 503"))
        ])
        let loader = loader(transport)
        let none = await loader.load(refresh: false)
        XCTAssertEqual(none, .failure(.unavailable(
            "Could not fetch the catalog from https://subset.21n.dev/catalog/v1.json (HTTP 503), and there is no cached copy."
        )))
        _ = try await loader.load(refresh: false).get()
        clock.advance(7 * 24 * 60 * 60)
        let expired = await loader.load(refresh: false)
        XCTAssertEqual(expired, .failure(.unavailable(
            "Could not fetch the catalog from https://subset.21n.dev/catalog/v1.json (HTTP 503), and the cached copy is 7 days old, more than 7 days."
        )))
    }

    func testARefusedFeedIsAnErrorAndKeepsTheCachedCopy() async throws {
        let transport = RecordedTransport([
            .success(try fixture("catalog-valid-live-only")), .success(try fixture("catalog-invalid-wrong-host")),
            .failure(FeedUnavailable("HTTP 503"))
        ])
        let loader = loader(transport)
        let good = try await loader.load(refresh: false).get()
        clock.advance(10 * 60)
        guard case .failure(.invalid(let message)) = await loader.load(refresh: false) else { return XCTFail("the feed is used") }
        XCTAssertTrue(message.hasPrefix("The catalog at https://subset.21n.dev/catalog/v1.json is not a valid subset.catalog@1 feed"), message)
        XCTAssertTrue(message.contains("/apps/0/channels/live/url"), message)
        // The cached copy is still the good feed.
        let offline = try await loader.load(refresh: false).get()
        XCTAssertEqual(offline.catalog, good.catalog)
        XCTAssertNotNil(offline.warning)
    }

    func testTheCacheIsSubsetsFormatAndOnlyServesItsOwnURL() async throws {
        let transport = RecordedTransport([.success(try fixture("catalog-valid-live-only")), .failure(FeedUnavailable("offline"))])
        _ = try await loader(transport).load(refresh: false).get()
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any])
        XCTAssertEqual(entry["schema"] as? String, "subset.catalog-cache@1")
        XCTAssertEqual(entry["url"] as? String, "https://subset.21n.dev/catalog/v1.json")
        XCTAssertEqual(entry["body"] as? String, String(decoding: try fixture("catalog-valid-live-only"), as: UTF8.self))
        XCTAssertEqual(entry["fetchedAt"] as? String, "2027-01-15T08:00:00.000Z")
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheFile.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        // Another feed URL does not use this copy.
        let other = loader(transport, url: URL(string: "https://subset.21n.dev/catalog/other.json")!)
        guard case .failure(.unavailable(let message)) = await other.load(refresh: false) else { return XCTFail("the cache is used") }
        XCTAssertTrue(message.hasSuffix("and there is no cached copy."), message)
    }

    func testACacheWrittenBySubsetWithoutFractionalSecondsIsRead() async throws {
        let body = String(decoding: try fixture("catalog-valid-live-only"), as: UTF8.self)
        let entry: [String: Any] = [
            "schema": "subset.catalog-cache@1", "url": "https://subset.21n.dev/catalog/v1.json", "fetchedAt": "2027-01-15T07:58:00Z",
            "body": body
        ]
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: entry).write(to: cacheFile)
        let transport = RecordedTransport([])
        let loaded = try await loader(transport).load(refresh: false).get()
        XCTAssertTrue(loaded.cached)
        XCTAssertEqual(transport.fetches, 0)
    }

    func testAnInvalidOrFutureCacheIsNotUsed() async throws {
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = String(decoding: try fixture("catalog-invalid-unknown-field"), as: UTF8.self)
        let valid = String(decoding: try fixture("catalog-valid-live-only"), as: UTF8.self)
        for (stamp, body) in [("2027-01-15T07:58:00Z", invalid), ("2027-01-15T09:00:00Z", valid)] {
            let entry: [String: Any] = [
                "schema": "subset.catalog-cache@1", "url": "https://subset.21n.dev/catalog/v1.json", "fetchedAt": stamp, "body": body
            ]
            try JSONSerialization.data(withJSONObject: entry).write(to: cacheFile)
            let transport = RecordedTransport([.failure(FeedUnavailable("offline"))])
            guard case .failure(.unavailable) = await loader(transport).load(refresh: false) else { return XCTFail("\(stamp) is used") }
        }
    }

    func testACacheEntryThatOnlyFoundationWouldReadIsNotUsed() async throws {
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry: [String: Any] = [
            "schema": "subset.catalog-cache@1", "url": "https://subset.21n.dev/catalog/v1.json", "fetchedAt": "2027-01-15T07:58:00Z",
            "body": String(decoding: try fixture("catalog-valid-live-only"), as: UTF8.self)
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self)
        try Data(text.utf8).write(to: cacheFile)
        let cached = try await loader(RecordedTransport([.failure(FeedUnavailable("offline"))])).load(refresh: false).get()
        XCTAssertTrue(cached.cached)
        // subset refuses a body with a lone surrogate (it is not well-formed Unicode), so it is not used here either.
        let lone = text.replacingOccurrences(of: "Take well-timed", with: "Take \\ud800 well-timed")
        XCTAssertNotEqual(lone, text)
        let variants = lenientVariants(of: text, property: #""url":"https://subset.21n.dev/catalog/other.json""#)
            + [("a lone surrogate in the body", Data(lone.utf8), "")]
        for (label, data, _) in variants {
            try data.write(to: cacheFile)
            let transport = RecordedTransport([.failure(FeedUnavailable("offline"))])
            guard case .failure(.unavailable) = await loader(transport).load(refresh: false) else {
                XCTFail("\(label) is used")
                continue
            }
        }
    }

    func testDurationsAreSaidAsPeopleSayThem() {
        XCTAssertEqual(CatalogLoader.describe(0), "0 seconds")
        XCTAssertEqual(CatalogLoader.describe(61), "1 minute")
        XCTAssertEqual(CatalogLoader.describe(2 * 86_400 + 5), "2 days")
    }
}
