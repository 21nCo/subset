import Foundation
import SQLite3
import Testing
@testable import PointInTimeCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pit-tests-\(UUID().uuidString)", isDirectory: true)
}

private func segment(_ bundleID: String?, _ from: TimeInterval, _ to: TimeInterval, title: String? = nil, url: String? = nil, excluded: Bool = false) -> Segment {
    Segment(start: t0 + from, end: t0 + to, excluded: excluded, bundleID: bundleID, appName: bundleID, windowTitle: title, url: url.flatMap(RedactedURL.init))
}

@Suite struct StoreTests {
    @Test func createsPrivateFolderAndDatabaseAtCurrentSchema() throws {
        let directory = temporaryDirectory().appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = try ActivityStore(directory: directory)
        #expect(try store.schemaVersion() == ActivityStore.supportedSchemaVersion)
        let folderMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.databaseURL.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(fileMode == 0o600)
        #expect(try store.segmentCount() == 0)
    }

    @Test func reopeningKeepsDataAndDoesNotReapplyMigrations() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ActivityStore(directory: directory).save(segment("a", 0, 60))
        let reopened = try ActivityStore(directory: directory)
        #expect(try reopened.segmentCount() == 1)
        #expect(try reopened.schemaVersion() == 1)
    }

    @Test func refusesNewerSchema() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databaseURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO schema_version VALUES (99, 0)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(throws: StoreError.newerSchema(found: 99, supported: 1)) { try ActivityStore(directory: directory) }
    }

    @Test func extendingAnOpenSegmentUpdatesItsBlocks() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("a", 0, 60, title: "Doc", url: "https://docs.example/d/1?edit=true"))
        try store.save(segment("a", 0, 400, title: "Doc", url: "https://docs.example/d/1?edit=true"))
        let segments = try store.segments(from: t0, to: t0 + 1_000)
        #expect(segments.count == 1 && segments[0].end == t0 + 400)
        #expect(segments[0].url?.string == "https://docs.example/d/1")
        let blocks = try store.blocks(from: t0, to: t0 + 1_000)
        #expect(blocks.map(\.start) == [t0, t0 + 180, t0 + 360])
        #expect(blocks.map(\.activeSeconds) == [180, 180, 40])
        #expect(blocks[0].dominantURL?.string == "https://docs.example/d/1")
    }

    @Test func excludedSegmentsStoreNoIdentity() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        let excluded = try #require(CapturePolicy(excludedBundleIDs: ["com.bank"]).content(
            for: Activity(bundleID: "com.bank", appName: "Bank", windowTitle: "Balance", url: RedactedURL("https://bank.example/a")), at: t0))
        var stored = excluded
        stored.end = t0 + 90
        try store.save(stored)
        let raw = try String(contentsOf: store.databaseURL, encoding: .isoLatin1) + ((try? String(contentsOf: URL(fileURLWithPath: store.databaseURL.path + "-wal"), encoding: .isoLatin1)) ?? "")
        #expect(!raw.contains("com.bank") && !raw.contains("Balance") && !raw.contains("bank.example"))
        let block = try #require(try store.blocks(from: t0, to: t0 + 180).first)
        #expect(block.excludedSeconds == 90 && block.activeSeconds == 0 && block.dominantBundleID == nil)
    }

    @Test func deletingADayTrimsSegmentsThatCrossItsEdges() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        let dayStart = t0 + 3_600, dayEnd = dayStart + 86_400
        try store.save(segment("before", 0, 3_000))
        try store.save(segment("crossesStart", 3_000, 3_700))
        try store.save(segment("inside", 4_000, 5_000))
        try store.save(segment("crossesEnd", 86_400 + 3_500, 86_400 + 3_700))
        try store.save(segment("after", 90_200, 90_300))
        try store.deleteData(from: dayStart, to: dayEnd)
        let remaining = try store.segments(from: .distantPast, to: .distantFuture)
        #expect(remaining.map { $0.bundleID ?? "" } == ["before", "crossesStart", "crossesEnd", "after"])
        #expect(remaining[1].end == dayStart)
        #expect(remaining[2].start == dayEnd && remaining[2].end == dayEnd + 100)
        #expect(try store.blocks(from: dayStart, to: dayEnd).isEmpty)
        #expect(!(try store.blocks(from: t0, to: dayStart).isEmpty))
    }

    @Test func deletingARangeInsideOneSegmentKeepsBothEnds() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("long", 0, 1_000, title: "T"))
        try store.deleteData(from: t0 + 200, to: t0 + 500)
        let remaining = try store.segments(from: .distantPast, to: .distantFuture)
        #expect(remaining.map { [$0.start, $0.end] } == [[t0, t0 + 200], [t0 + 500, t0 + 1_000]])
        #expect(remaining.allSatisfy { $0.windowTitle == "T" })
        #expect(try store.blocks(from: t0 + 360, to: t0 + 360).isEmpty)
    }

    @Test func deleteAllLeavesAnEmptyCompactedDatabase() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("com.secret.app", 0, 600, title: "Very private title"))
        try store.deleteAll()
        #expect(try store.segmentCount() == 0)
        #expect(try store.blocks(from: .distantPast, to: .distantFuture).isEmpty)
        let bytes = try Data(contentsOf: store.databaseURL)
        let wal = (try? Data(contentsOf: URL(fileURLWithPath: store.databaseURL.path + "-wal"))) ?? Data()
        #expect(bytes.range(of: Data("Very private title".utf8)) == nil)
        #expect(wal.range(of: Data("Very private title".utf8)) == nil)
    }
}
