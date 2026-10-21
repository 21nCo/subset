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

private func content(_ bundleID: String, _ title: String) -> Segment? {
    CapturePolicy().content(for: Activity(bundleID: bundleID, appName: bundleID, windowTitle: title), at: t0)
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
        // SQLite gives the WAL and shared-memory files the database's mode.
        try store.save(segment("a", 0, 60, title: "T"))
        for suffix in ["-wal", "-shm"] {
            let mode = try FileManager.default.attributesOfItem(atPath: store.databaseURL.path + suffix)[.posixPermissions] as? Int
            #expect(mode == 0o600, "activity.sqlite\(suffix)")
        }
    }

    @Test func refusesToOpenADatabaseWhoseModeCannotBeRestricted() throws {
        let directory = temporaryDirectory()
        let database = directory.appendingPathComponent("activity.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: database.path, contents: nil, attributes: [.posixPermissions: 0o644]))
        // An immutable file refuses chmod, even from its owner.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: database.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: database.path)
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            _ = try ActivityStore(directory: directory)
            Issue.record("The store opened a database it could not restrict to mode 0600")
        } catch StoreError.filesystem {
        } catch {
            Issue.record("Expected a filesystem error, got \(error)")
        }
    }

    @Test func textWithAnEmbeddedNulRoundTrips() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("a", 0, 60, title: "before\u{0}after"))
        #expect(try store.segments(from: t0, to: t0 + 60).first?.windowTitle == "before\u{0}after")
    }

    @Test func capturedTextIsBoundedInStorageBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        let marks = String(repeating: "\u{0301}", count: 100_000)
        let activity = Activity(bundleID: "com.example." + String(repeating: "x", count: 1_000), appName: "App" + marks,
                                windowTitle: "Report" + marks, url: RedactedURL("https://example.com/" + String(repeating: "p", count: 5_000)))
        var captured = try #require(CapturePolicy().content(for: activity, at: t0))
        captured.end = t0 + 60
        try store.save(captured)

        #expect(try store.blocks(from: t0, to: t0 + 60).first?.dominantTitle == "Repor")
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, """
            SELECT length(CAST(s.window_title AS BLOB)), length(CAST(s.app_name AS BLOB)), length(CAST(s.bundle_id AS BLOB)),
                   length(CAST(s.url_path AS BLOB)), length(CAST(b.dominant_title AS BLOB)), length(CAST(b.apps_json AS BLOB))
            FROM segments s, blocks b
            """, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        let lengths = (0..<6).map { Int(sqlite3_column_int64(statement, Int32($0))) }
        #expect(lengths[0] <= Activity.maxTitleBytes && lengths[4] <= Activity.maxTitleBytes)
        #expect(lengths[1] <= Segment.maxIdentityBytes && lengths[2] <= Segment.maxIdentityBytes)
        #expect(lengths[3] <= RedactedURL.maxPathBytes)
        #expect(lengths[5] <= 2 * Segment.maxIdentityBytes + 100)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        // Schema version 2's tables and indexes add a few pages; unbounded text would add about 200 KB.
        #expect(bytes < 120_000, "the store directory holds \(bytes) bytes after one segment")
    }

    /// Segments built directly, not through `Activity`, stay bounded through a save, the tail a deletion re-inserts, and
    /// the blocks rebuilt after reopening.
    @Test func directlyBuiltSegmentsStayBoundedThroughEveryStoreWrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marks = String(repeating: "\u{0301}", count: 100_000)
        let titles = ["Report" + marks, String(repeating: "\u{8A9E}", count: 400),
                      String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 100)]
        do {
            let store = try ActivityStore(directory: directory)
            for (index, title) in titles.enumerated() {
                let start = Double(index) * 600
                try store.save(Segment(start: t0 + start, end: t0 + start + 400, excluded: false, bundleID: "com.example." + marks,
                                       appName: "App" + marks, windowTitle: title, url: nil))
                // Deleting inside the segment re-inserts its tail.
                try store.deleteData(from: t0 + start + 100, to: t0 + start + 200)
            }
            #expect(try store.segments(from: .distantPast, to: .distantFuture).first?.windowTitle == "Repor")
        }
        let reopened = try ActivityStore(directory: directory)
        try reopened.save(segment("b", 1_790, 1_800))
        // A deletion inside a tail read back from the reopened store re-inserts that tail again.
        try reopened.deleteData(from: t0 + 250, to: t0 + 260)

        var db: OpaquePointer?
        #expect(sqlite3_open(reopened.databaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func longest(_ column: String, in table: String) -> Int {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT MAX(length(CAST(\(column) AS BLOB))) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return .max }
            return Int(sqlite3_column_int64(statement, 0))
        }
        #expect(longest("window_title", in: "segments") <= Activity.maxTitleBytes)
        #expect(longest("dominant_title", in: "blocks") <= Activity.maxTitleBytes)
        #expect(longest("app_name", in: "segments") <= Segment.maxIdentityBytes)
        #expect(longest("bundle_id", in: "segments") <= Segment.maxIdentityBytes)
        #expect(longest("dominant_app_name", in: "blocks") <= Segment.maxIdentityBytes)
        #expect(longest("apps_json", in: "blocks") <= 2 * Segment.maxIdentityBytes + 100)
        #expect(try reopened.segmentCount() == 3 * 2 + 2)
    }

    @Test func emptyOrReversedRangesReadNothing() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("a", 0, 300))
        for (from, to) in [(t0 + 100, t0 + 100), (t0 + 200, t0 + 100)] {
            #expect(try store.segments(from: from, to: to).isEmpty)
            #expect(try store.blocks(from: from, to: to).isEmpty)
        }
        #expect(try store.segments(from: t0 + 100, to: t0 + 101).count == 1)
    }

    @Test func reopeningKeepsDataAndDoesNotReapplyMigrations() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ActivityStore(directory: directory).save(segment("a", 0, 60))
        let reopened = try ActivityStore(directory: directory)
        #expect(try reopened.segmentCount() == 1)
        #expect(try reopened.schemaVersion() == ActivityStore.supportedSchemaVersion)
    }

    @Test func refusesNewerSchema() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databaseURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO schema_version VALUES (99, 0)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(throws: StoreError.newerSchema(found: 99, supported: 2)) { try ActivityStore(directory: directory) }
    }

    @Test func refusesANewerSchemaWithoutTouchingItsJournalOrBytes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("activity.sqlite").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
            PRAGMA journal_mode=DELETE;
            CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            INSERT INTO schema_version VALUES (3, 0);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        #expect(throws: StoreError.newerSchema(found: 3, supported: 2)) { try ActivityStore(directory: directory) }

        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: path + suffix), "activity.sqlite\(suffix)")
        }
        // Header bytes 18 and 19 are 1 for a rollback journal and 2 for WAL.
        #expect(before[18] == 1 && before[19] == 1)
    }

    @Test(arguments: [true, false])
    func refusesANewerWALDatabaseWithoutCheckpointingIt(keepSharedMemory: Bool) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("activity.sqlite").path
        // A newer version left frames in its WAL that were never checkpointed, as after a crash: copy the files while
        // the writer still has them open, then put the copies back after it closes.
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            INSERT INTO schema_version VALUES (2, 0);
            PRAGMA wal_checkpoint(TRUNCATE);
            PRAGMA wal_autocheckpoint=0;
            INSERT INTO schema_version VALUES (3, 0);
            CREATE TABLE newer (value TEXT);
            """, nil, nil, nil) == SQLITE_OK)
        let suffixes = keepSharedMemory ? ["", "-wal", "-shm"] : ["", "-wal"]
        let crashed = try suffixes.map { try Data(contentsOf: URL(fileURLWithPath: path + $0)) }
        sqlite3_close(db)
        for (suffix, bytes) in zip(suffixes, crashed) { try bytes.write(to: URL(fileURLWithPath: path + suffix)) }
        try? FileManager.default.removeItem(atPath: path + (keepSharedMemory ? "-journal" : "-shm"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path + "-wal")).count > 0)

        #expect(throws: StoreError.newerSchema(found: 3, supported: 2)) { try ActivityStore(directory: directory) }

        // The database and its WAL are unchanged. With its -shm present nothing changes at all; without it, SQLite
        // needs a writable WAL index to read the WAL and may create one.
        for (suffix, bytes) in zip(suffixes, crashed) where suffix != "-shm" || keepSharedMemory {
            let unchanged = (try? Data(contentsOf: URL(fileURLWithPath: path + suffix))) == bytes
            #expect(unchanged, "activity.sqlite\(suffix)")
        }
        #expect(!FileManager.default.fileExists(atPath: path + "-journal"))
    }

    @Test func aStoreClosedBeforeItsFirstWriteOpensAgain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Launched and quit before recording anything: the database is in WAL mode but has no WAL or -shm file yet.
        _ = try ActivityStore(directory: directory)
        let path = directory.appendingPathComponent("activity.sqlite").path
        #expect(!FileManager.default.fileExists(atPath: path + "-wal") && !FileManager.default.fileExists(atPath: path + "-shm"))
        let header = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(header[18] == 2 && header[19] == 2)

        let reopened = try ActivityStore(directory: directory)
        try reopened.save(segment("a", 0, 60, title: "After relaunch"))
        #expect(try reopened.segments(from: .distantPast, to: .distantFuture).map(\.windowTitle) == ["After relaunch"])
    }

    @Test func refusesANewerWALDatabaseWithoutAWALFileAndCreatesNothing() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("activity.sqlite").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            INSERT INTO schema_version VALUES (3, 0);
            PRAGMA wal_checkpoint(TRUNCATE);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(before[18] == 2 && before[19] == 2)

        #expect(throws: StoreError.newerSchema(found: 3, supported: 2)) { try ActivityStore(directory: directory) }

        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: path + suffix), "activity.sqlite\(suffix)")
        }
    }

    @Test func refusesASchemaThatAdvancesAfterTheReadOnlyCheck() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ActivityStore(directory: directory).save(segment("a", 0, 60, title: "Kept"))
        let path = directory.appendingPathComponent("activity.sqlite").path
        func contents() -> [String] {
            var db: OpaquePointer?
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement); sqlite3_close(db) }
            guard sqlite3_open(path, &db) == SQLITE_OK, sqlite3_prepare_v2(db, """
                SELECT 'table ' || name FROM sqlite_master UNION ALL SELECT 'version ' || version FROM schema_version
                UNION ALL SELECT 'segment ' || start || ' ' || end || ' ' || window_title FROM segments
                """, -1, &statement, nil) == SQLITE_OK else { return [] }
            var rows: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
            return rows.sorted()
        }

        var advanced: [String] = []
        #expect(throws: StoreError.newerSchema(found: 3, supported: 2)) {
            try ActivityStore(directory: directory) {
                // Another, newer copy of the app migrates the database after the read-only check passed.
                var db: OpaquePointer?
                #expect(sqlite3_open(path, &db) == SQLITE_OK)
                #expect(sqlite3_exec(db, "INSERT INTO schema_version VALUES (3, 0)", nil, nil, nil) == SQLITE_OK)
                sqlite3_close(db)
                advanced = contents()
            }
        }
        #expect(advanced.contains("version 3") && advanced.contains { $0.hasPrefix("segment ") })
        #expect(contents() == advanced)
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

    @Test func shrinkingAFlushedSegmentClearsTheBucketsPastItsNewEnd() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("a", 0, 300, title: "Doc"))
        try store.save(segment("a", 0, 130, title: "Doc")) // idle began at t0 + 130
        #expect(try store.segments(from: .distantPast, to: .distantFuture).map(\.end) == [t0 + 130])
        let blocks = try store.blocks(from: t0, to: t0 + 1_000)
        #expect(blocks.map(\.start) == [t0])
        #expect(blocks.map(\.activeSeconds) == [130])
    }

    @Test func savingAnEmptySegmentRetractsTheFlushedOne() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("a", 0, 100))
        try store.save(segment("b", 150, 250, title: "Flushed"))
        try store.save(segment("b", 150, 150, title: "Flushed")) // the recorder's empty close
        #expect(try store.segments(from: .distantPast, to: .distantFuture).map { $0.bundleID ?? "" } == ["a"])
        let blocks = try store.blocks(from: t0, to: t0 + 1_000)
        #expect(blocks.map(\.start) == [t0] && blocks.first?.activeSeconds == 100)
        #expect(blocks.first?.apps.map(\.bundleID) == ["a"])
        try store.save(segment("never", 500, 500)) // nothing stored for it: a no-op
        #expect(try store.segmentCount() == 1)
    }

    @Test func idleRetractionLeavesNothingAfterIdleBegan() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        var recorder = SegmentRecorder()
        // Input stops at t0 + 100. A title change without input at t0 + 150 closes "one"; "two" is flushed at t0 + 210.
        for second in stride(from: 0.0, through: 145, by: 5) { _ = recorder.record(content("app", "one"), at: t0 + second) }
        for closed in recorder.record(content("app", "two"), at: t0 + 150) { try store.save(closed) }
        for second in stride(from: 155.0, through: 210, by: 5) { _ = recorder.record(content("app", "two"), at: t0 + second) }
        try store.save(try #require(recorder.open))
        // The idle threshold is reached at t0 + 220: the host ends the segment at idle start and retracts the rest.
        let idleStart = t0 + 100, now = t0 + 220
        let closed = recorder.gap(at: idleStart)
        try store.save(try #require(closed))
        try store.deleteData(from: idleStart, to: now)
        let remaining = try store.segments(from: .distantPast, to: .distantFuture)
        #expect(remaining.map(\.windowTitle) == ["one"] && remaining.map(\.end) == [idleStart])
        let blocks = try store.blocks(from: t0, to: t0 + 1_000)
        #expect(blocks.map(\.start) == [t0] && blocks.map(\.activeSeconds) == [100])
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

    @Test func deletingTodayThroughDistantFutureIsBoundedByStoredData() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        let midnight = t0 + 86_400
        try store.save(segment("yesterday", 0, 600, title: "Y"))
        try store.save(segment("crossesMidnight", 86_400 - 100, 86_400 + 200, title: "C"))
        try store.save(segment("today", 86_400 + 1_000, 86_400 + 1_400, title: "T"))
        let clock = ContinuousClock()
        let elapsed = try clock.measure { try store.deleteData(from: midnight, to: .distantFuture) } // exactly as the menu calls it
        #expect(elapsed < .seconds(2))
        let remaining = try store.segments(from: .distantPast, to: .distantFuture)
        #expect(remaining.map { $0.bundleID ?? "" } == ["yesterday", "crossesMidnight"])
        #expect(remaining[1].end == midnight)
        #expect(try store.blocks(from: midnight, to: .distantFuture).isEmpty)
        let before = try store.blocks(from: t0, to: midnight)
        #expect(before.reduce(0) { $0 + $1.activeSeconds } == 700)
        #expect(before.last?.start == midnight - 180 && before.last?.activeSeconds == 100)
        try store.checkpoint()
        let wal = (try? Data(contentsOf: URL(fileURLWithPath: store.databaseURL.path + "-wal"))) ?? Data()
        #expect(wal.isEmpty)
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
        let blocks = try store.blocks(from: .distantPast, to: .distantFuture)
        #expect(blocks.map { [$0.start.timeIntervalSince(t0), $0.activeSeconds] } == [[0, 180], [180, 20], [360, 40], [540, 180], [720, 180], [900, 100]])
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

/// Another connection in a read transaction, which keeps a WAL checkpoint from completing until it ends.
private func withReader(on store: ActivityStore, _ body: (_ release: () throws -> Void) throws -> Void) throws {
    let reader = try SQLiteConnection(path: store.databaseURL.path)
    try reader.execute("BEGIN")
    try reader.query("SELECT COUNT(*) FROM segments")
    var open = true
    defer { if open { try? reader.execute("COMMIT") } }
    try body { try reader.execute("COMMIT"); open = false }
}

/// Another connection holding the write lock, as another process writing the database would.
private func withWriter(on store: ActivityStore, _ body: (_ release: () throws -> Void) throws -> Void) throws {
    let writer = try SQLiteConnection(path: store.databaseURL.path)
    try writer.execute("BEGIN IMMEDIATE")
    var open = true
    defer { if open { try? writer.execute("COMMIT") } }
    try body { try writer.execute("COMMIT"); open = false }
}

/// The longest a contended store call may block its caller, which is the main actor in the app.
private let callerBudget = Duration.milliseconds(250)

/// Runs `body` and expects it to return within `callerBudget`, whether it throws or not. Call it outside `#expect` and
/// assert its result: Swift 6.2 can give a closure written inside `#expect` the symbol of an earlier closure of the
/// same type in the same scope, and then runs that one instead.
private func expectFast<T>(_ what: String, _ body: () throws -> T) -> T? {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try? body()
    let elapsed = clock.now - start
    #expect(elapsed < callerBudget, "\(what) took \(elapsed)")
    return result
}

private func contains(_ text: String, _ store: ActivityStore, _ suffix: String) -> Bool {
    let bytes = (try? Data(contentsOf: URL(fileURLWithPath: store.databaseURL.path + suffix))) ?? Data()
    return bytes.range(of: Data(text.utf8)) != nil
}

@Suite struct CheckpointTests {
    @Test func deleteAllFailsWhileAReaderBlocksItsCheckpointAndCompletesAfterwards() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try withReader(on: store) { release in
            try store.save(segment("com.secret.app", 0, 600, title: "SECRET-TITLE"))
            // A blocked checkpoint fails at once instead of waiting for the reader, on every attempt.
            for attempt in 1...3 {
                _ = expectFast("deleteAll attempt \(attempt)") { #expect(throws: StoreError.self) { try store.deleteAll() } }
            }
            // The rows are deleted, but the WAL still holds the title, so the deletion is not done.
            #expect(try store.segmentCount() == 0)
            #expect(contains("SECRET-TITLE", store, "-wal"))
            try release()
            try store.deleteAll()
        }
        #expect(!contains("SECRET-TITLE", store, "") && !contains("SECRET-TITLE", store, "-wal"))
    }

    /// A reader that began after the deletion lets every frame be copied, but it still keeps the WAL, which holds the
    /// deleted title, from being truncated.
    @Test func aCheckpointThatCannotTruncateTheWALIsAFailure() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("com.secret.app", 0, 600, title: "SECRET-TITLE"))
        try store.deleteData(from: t0, to: t0 + 600)
        try withReader(on: store) { release in
            for attempt in 1...3 {
                _ = expectFast("checkpoint attempt \(attempt)") { #expect(throws: StoreError.self) { try store.checkpoint() } }
            }
            #expect(contains("SECRET-TITLE", store, "-wal"))
            try release()
            try store.checkpoint()
        }
        #expect(!contains("SECRET-TITLE", store, "") && !contains("SECRET-TITLE", store, "-wal"))
    }

    enum Removal: CaseIterable { case idleRetraction, deleteToday, deleteAll }

    /// A removal whose checkpoint a reader blocks stays queued, with its error shown, and the retry after the reader
    /// ends removes the text from the database and its WAL.
    @Test(arguments: Removal.allCases)
    func aRemovalWhoseCheckpointIsBlockedStaysQueuedUntilItCompletes(_ removal: Removal) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        var writes = PendingWrites()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        try withReader(on: store) { release in
            writes.save(segment("com.google.Chrome", 0, 120, title: "SECRET-TITLE", url: "https://secret.example.com/plan"), to: store)
            #expect(writes.failure == nil)
            _ = expectFast("\(removal)") {
                switch removal {
                case .idleRetraction: writes.retract(since: t0, until: t0 + 200, in: store)
                case .deleteToday: writes.deleteDay(containing: t0 + 200, calendar: utc, in: store)
                case .deleteAll: writes.deleteAll(in: store)
                }
            }
            // Each sample's retry fails fast and keeps the removal queued with its error shown.
            for attempt in 1...3 {
                let drained = expectFast("retry \(attempt)") { writes.retry(store) }
                #expect(drained == false)
                #expect(writes.failure != nil && writes.hasPendingDeletion)
            }
            #expect(contains("SECRET-TITLE", store, "-wal"))
            try release()
            let drained = writes.retry(store)
            #expect(drained && writes.failure == nil && writes.isEmpty)
        }
        #expect(try store.segmentCount() == 0)
        for suffix in ["", "-wal"] {
            #expect(!contains("SECRET-TITLE", store, suffix) && !contains("secret.example.com", store, suffix), "activity.sqlite\(suffix)")
        }
    }
}

/// Another process holding the write lock delays capture's writes, not the app: each write fails within the budget, stays
/// queued in order, and is applied once the lock is released.
@Suite struct WriteContentionTests {
    @Test func storeWritesBlockedByAnotherWriterFailWithinTheBudget() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        try store.save(segment("com.apple.TextEdit", 0, 60, title: "Kept"))
        try withWriter(on: store) { release in
            for attempt in 1...3 {
                _ = expectFast("save \(attempt)") { #expect(throws: StoreError.self) { try store.save(segment("com.apple.Notes", 60, 120)) } }
                _ = expectFast("deleteData \(attempt)") { #expect(throws: StoreError.self) { try store.deleteData(from: t0, to: t0 + 60) } }
                _ = expectFast("deleteAll \(attempt)") { #expect(throws: StoreError.self) { try store.deleteAll() } }
                _ = expectFast("checkpoint \(attempt)") { #expect(throws: StoreError.self) { try store.checkpoint() } }
            }
            try release()
        }
        #expect(try store.segments(from: .distantPast, to: .distantFuture).map(\.windowTitle) == ["Kept"])
    }

    @Test func queuedWritesBlockedByAnotherWriterFailFastAndApplyInOrderAfterwards() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActivityStore(directory: directory)
        var writes = PendingWrites()
        try withWriter(on: store) { release in
            _ = expectFast("save") { writes.save(segment("com.apple.TextEdit", 0, 120, title: "Draft"), to: store) }
            _ = expectFast("retract") { writes.retract(since: t0 + 60, until: t0 + 130, in: store) }
            _ = expectFast("save after") { writes.save(segment("com.apple.Notes", 130, 200, title: "Notes"), to: store) }
            for attempt in 1...3 {
                let drained = expectFast("retry \(attempt)") { writes.retry(store) }
                #expect(drained == false)
            }
            #expect(writes.failure != nil && writes.count == 3, "\(writes.queue)")
            try release()
        }
        #expect(writes.retry(store) && writes.failure == nil)
        // Applied in request order: the retraction shortens the first save and leaves the later one.
        let stored = try store.segments(from: .distantPast, to: .distantFuture)
        #expect(stored.map { [$0.start.timeIntervalSince(t0), $0.end.timeIntervalSince(t0)] } == [[0, 60], [130, 200]])
        #expect(stored.map(\.windowTitle) == ["Draft", "Notes"])
    }
}

/// A store whose writes can be made to fail, as a full disk or a locked file would. It logs every call it receives.
private final class FlakyStorage: CaptureStorage {
    let store: ActivityStore
    var failSaves = false, failDeletes = false, failCheckpoints = false, failReads = false
    var calls: [String] = []

    init(_ store: ActivityStore) { self.store = store }

    private func fail(_ when: Bool) throws { if when { throw StoreError.sqlite("disk I/O error") } }
    func save(_ segment: Segment) throws {
        calls.append("save \(Int(segment.start.timeIntervalSince(t0)))")
        try fail(failSaves); try store.save(segment)
    }
    func deleteData(from: Date, to: Date) throws {
        calls.append("delete \(Int(from.timeIntervalSince(t0)))")
        try fail(failDeletes); try store.deleteData(from: from, to: to)
    }
    func checkpoint() throws { calls.append("checkpoint"); try fail(failCheckpoints); try store.checkpoint() }
    func removeAll() throws { calls.append("deleteAll"); try fail(failDeletes); try store.removeAll() }
    func compact() throws { calls.append("compact"); try fail(failCheckpoints); try store.compact() }
    func latestSegmentEnd() throws -> Date? { try fail(failReads); return try store.latestSegmentEnd() }
}

private func withStorage(_ body: (FlakyStorage) throws -> Void) throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(FlakyStorage(try ActivityStore(directory: directory)))
}

@Suite struct PendingWritesTests {
    @Test func aFailedIdleRetractionIsRetriedUntilTheIdleActivityIsGone() throws {
        try withStorage { storage in
            var writes = PendingWrites()
            // Flushed while the user was in fact away since t0 + 30, then a title change without input closed it.
            writes.save(segment("com.google.Chrome", 0, 120, title: "Secret plan", url: "https://example.com/secret?q=1"), to: storage)
            writes.save(segment("com.google.Chrome", 120, 150, title: "Inbox (3)", url: "https://mail.example.com/inbox"), to: storage)
            #expect(writes.failure == nil)

            // Idle is detected while storage fails: the open segment ends when idle began, and the retraction fails.
            storage.failSaves = true; storage.failDeletes = true
            writes.save(segment("com.google.Chrome", 0, 30, title: "Secret plan", url: "https://example.com/secret?q=1"), to: storage)
            writes.retract(since: t0 + 30, until: t0 + 180, in: storage)
            #expect(writes.failure != nil)

            // Saves work again but deletion still fails: a later, unrelated save neither runs ahead of the retraction nor
            // clears the error.
            storage.failSaves = false
            writes.save(segment("com.apple.TextEdit", 200, 260, title: "Notes"), to: storage)
            #expect(writes.failure != nil)
            #expect(try storage.store.segments(from: t0 + 30, to: t0 + 180).map(\.windowTitle) == ["Inbox (3)"])
            #expect(try storage.store.segments(from: t0 + 200, to: t0 + 260).isEmpty)

            // The checkpoint failing after a successful delete keeps the retraction queued as well.
            storage.failDeletes = false; storage.failCheckpoints = true
            let stillFailing = writes.retry(storage)
            #expect(!stillFailing)
            storage.failCheckpoints = false
            let drained = writes.retry(storage)
            #expect(drained)
            #expect(writes.failure == nil && writes.isEmpty)

            let stored = try storage.store.segments(from: .distantPast, to: .distantFuture)
            #expect(stored.map { [$0.start.timeIntervalSince(t0), $0.end.timeIntervalSince(t0)] } == [[0, 30], [200, 260]])
            let blocks = try storage.store.blocks(from: .distantPast, to: .distantFuture)
            #expect(blocks.map { [$0.start.timeIntervalSince(t0), $0.activeSeconds] } == [[0, 30], [180, 60]])
            for suffix in ["", "-wal"] {
                let bytes = (try? Data(contentsOf: URL(fileURLWithPath: storage.store.databaseURL.path + suffix))) ?? Data()
                #expect(bytes.range(of: Data("Inbox (3)".utf8)) == nil && bytes.range(of: Data("mail.example.com".utf8)) == nil, "activity.sqlite\(suffix)")
            }
        }
    }

    @Test func aFailedSaveIsKeptAndRetriedWithItsNewestEnd() throws {
        try withStorage { storage in
            var writes = PendingWrites()
            storage.failSaves = true
            writes.save(segment("a", 0, 60, title: "Draft"), to: storage)
            writes.save(segment("a", 0, 90, title: "Draft"), to: storage)
            writes.save(segment("b", 90, 120), to: storage)
            #expect(writes.failure != nil)
            storage.failSaves = false
            let drained = writes.retry(storage)
            #expect(drained)
            let stored = try storage.store.segments(from: .distantPast, to: .distantFuture)
            #expect(stored.map { [$0.start.timeIntervalSince(t0), $0.end.timeIntervalSince(t0)] } == [[0, 90], [90, 120]])
        }
    }

    @Test func deleteAllDropsQueuedWritesSoNothingComesBack() throws {
        try withStorage { storage in
            var writes = PendingWrites()
            writes.save(segment("a", 0, 60, title: "Kept until deleted"), to: storage)
            storage.failSaves = true; storage.failDeletes = true
            writes.save(segment("a", 0, 120, title: "Kept until deleted"), to: storage)
            writes.deleteAll(in: storage)
            #expect(writes.failure != nil)
            storage.failSaves = false; storage.failDeletes = false
            let drained = writes.retry(storage)
            #expect(drained)
            let remaining = try storage.store.segmentCount()
            #expect(remaining == 0)
        }
    }

    @Test func appliedRemovalsCountsADeletionWhenItReachesStorageNotWhenItIsQueued() throws {
        try withStorage { storage in
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            var writes = PendingWrites()
            writes.save(segment("a", 0, 60), to: storage)
            #expect(writes.appliedRemovals == 0)
            writes.deleteDay(containing: t0 + 90, calendar: utc, in: storage)
            #expect(writes.appliedRemovals == 1)

            storage.failDeletes = true
            writes.deleteAll(in: storage)
            writes.retry(storage)
            #expect(writes.hasPendingDeletion && writes.appliedRemovals == 1)
            // A save behind the queued deletion succeeding alone is not a removal.
            storage.failDeletes = false
            writes.save(segment("b", 120, 180), to: storage)
            #expect(!writes.hasPendingDeletion && writes.appliedRemovals == 2)
            writes.save(segment("b", 180, 240), to: storage)
            #expect(writes.appliedRemovals == 2)
        }
    }

    @Test func appliedRemovalsCountsADeletionOnceItsRowsAreGoneEvenWhenTheCheckpointAfterItFails() throws {
        try withStorage { storage in
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            var writes = PendingWrites()
            writes.save(segment("a", 0, 60), to: storage)
            storage.failCheckpoints = true
            writes.deleteDay(containing: t0 + 90, calendar: utc, in: storage)
            #expect(writes.hasPendingDeletion)
            let stored = try storage.store.segmentCount()
            #expect(stored == 0)
            #expect(writes.appliedRemovals == 1)
            // Retrying the delete step while the checkpoint still fails removes nothing new and is not counted again.
            writes.retry(storage)
            #expect(writes.appliedRemovals == 1)
            storage.failCheckpoints = false
            writes.retry(storage)
            #expect(!writes.hasPendingDeletion && writes.appliedRemovals == 1)

            writes.save(segment("b", 120, 180), to: storage)
            storage.failCheckpoints = true
            writes.deleteAll(in: storage)
            #expect(writes.hasPendingDeletion)
            let remaining = try storage.store.segmentCount()
            #expect(remaining == 0)
            #expect(writes.appliedRemovals == 2)
            storage.failCheckpoints = false
            writes.retry(storage)
            #expect(!writes.hasPendingDeletion && writes.appliedRemovals == 2)
        }
    }

    @Test func aRetractionWideningTheQueuedHeadCountsItsDeleteAgain() throws {
        try withStorage { storage in
            var writes = PendingWrites()
            writes.save(segment("a", 0, 60), to: storage)
            writes.save(segment("b", 60, 80), to: storage)
            storage.failCheckpoints = true
            writes.retract(since: t0 + 70, until: t0 + 90, in: storage)
            let trimmed = try storage.store.segmentCount()
            #expect(trimmed == 2 && writes.count == 1 && writes.appliedRemovals == 1)
            // It merges into the queued head, whose delete step already ran; the wider delete removes rows the first did not.
            writes.retract(since: t0, until: t0 + 100, in: storage)
            #expect(writes.queue == [.retract(from: t0, to: t0 + 100)])
            let remaining = try storage.store.segmentCount()
            #expect(remaining == 0 && writes.appliedRemovals == 2)
            writes.retry(storage)
            #expect(writes.appliedRemovals == 2)
            storage.failCheckpoints = false
            let drained = writes.retry(storage)
            #expect(drained && writes.appliedRemovals == 2)
        }
    }

    @Test func aSustainedOutageKeepsTheQueueBoundedAndStillAdmitsDeletions() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 10, writesPerRetry: 4)
            storage.failSaves = true; storage.failDeletes = true
            for index in 0..<1_000 { writes.save(segment("a", Double(index) * 10, Double(index) * 10 + 5), to: storage) }
            #expect(writes.count == 10)
            #expect(writes.queue.first == .save(segment("a", 0, 5)) && writes.queue.last == .save(segment("a", 90, 95)))

            // A retraction is admitted at capacity and drops the queued saves it covers.
            writes.retract(since: t0 + 50, until: t0 + 200, in: storage)
            #expect(writes.count == 6 && writes.hasPendingDeletion)
            // Retractions that follow it directly merge with it, so they never grow the queue.
            for index in 0..<100 { writes.retract(since: t0 + 1_000 + Double(index) * 500, until: t0 + 1_100 + Double(index) * 500, in: storage) }
            #expect(writes.count == 6)
            #expect(writes.queue.last == .retract(from: t0 + 50, to: t0 + 1_100 + 99 * 500))

            writes.deleteAll(in: storage)
            #expect(writes.queue == [.deleteAll] && writes.failure != nil)
        }
    }

    @Test func aLargeRecoveryAppliesABoundedNumberOfWritesPerRetryInOrder() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 200, writesPerRetry: 8)
            storage.failSaves = true
            for index in 0..<150 { writes.save(segment("a", Double(index) * 10, Double(index) * 10 + 5), to: storage) }
            #expect(writes.count == 150)
            storage.failSaves = false
            storage.calls = []
            var rounds = 0
            // Bounded, so a queue that stopped draining fails the test instead of hanging it.
            for _ in 0..<50 where !writes.isEmpty {
                let drained = writes.retry(storage)
                rounds += 1
                #expect(storage.calls.count == min(8 * rounds, 150))
                #expect(drained == writes.isEmpty && (writes.failure == nil) == drained)
            }
            #expect(rounds == 19 && writes.failure == nil && writes.isEmpty)
            #expect(storage.calls == (0..<150).map { "save \($0 * 10)" })
            let stored = try storage.store.segmentCount()
            #expect(stored == 150)
        }
    }

    @Test func aRetractionAdmittedAtCapacityLeavesNoRetractedActivity() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 4, writesPerRetry: 8)
            writes.save(segment("com.google.Chrome", 0, 60, title: "Secret plan", url: "https://secret.example.com/plan?q=1"), to: storage)
            storage.failSaves = true; storage.failDeletes = true
            writes.save(segment("com.google.Chrome", 0, 120, title: "Secret plan", url: "https://secret.example.com/plan?q=1"), to: storage)
            for index in 1...5 { writes.save(segment("b", 120 + Double(index) * 10, 125 + Double(index) * 10, title: "Away \(index)"), to: storage) }
            #expect(writes.count == 4)
            writes.save(segment("com.google.Chrome", 0, 20, title: "Secret plan", url: "https://secret.example.com/plan?q=1"), to: storage)
            #expect(writes.count == 4)

            // Idle began at 20; the shorter save above was refused, so the retraction alone has to remove the rest.
            writes.retract(since: t0 + 20, until: t0 + 400, in: storage)
            storage.failSaves = false; storage.failDeletes = false
            let drained = writes.retry(storage)
            #expect(drained && writes.failure == nil)
            let stored = try storage.store.segments(from: .distantPast, to: .distantFuture)
            #expect(stored.map { [$0.start.timeIntervalSince(t0), $0.end.timeIntervalSince(t0)] } == [[0, 20]])
            for suffix in ["", "-wal"] {
                let bytes = (try? Data(contentsOf: URL(fileURLWithPath: storage.store.databaseURL.path + suffix))) ?? Data()
                #expect(bytes.range(of: Data("Away".utf8)) == nil, "activity.sqlite\(suffix)")
            }
        }
    }

    @Test func aFailedDeleteTodayNeverRemovesCapturesMadeAfterIt() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 4, writesPerRetry: 8)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            writes.save(segment("com.google.Chrome", 0, 60, title: "Morning plan", url: "https://morning.example.com/plan"), to: storage)
            // Delete Today fails; it ends the open segment first, as the app does.
            storage.failSaves = true; storage.failDeletes = true
            writes.save(segment("com.google.Chrome", 0, 100, title: "Morning plan", url: "https://morning.example.com/plan"), to: storage)
            writes.deleteDay(containing: t0 + 100, calendar: utc, in: storage)
            // Three captures made after the request fill the queue; the last one was flushed while the user was away.
            writes.save(segment("a", 100, 150, title: "After one"), to: storage)
            writes.save(segment("b", 150, 200, title: "After two"), to: storage)
            writes.save(segment("c", 200, 260, title: "After three"), to: storage)
            #expect(writes.count == 4)
            // Idle began at 230: the open segment ends there and the rest is retracted, at capacity.
            writes.save(segment("c", 200, 230, title: "After three"), to: storage)
            writes.retract(since: t0 + 230, until: t0 + 400, in: storage)
            #expect(writes.count == 5)

            storage.failSaves = false; storage.failDeletes = false
            let drained = writes.retry(storage)
            #expect(drained && writes.failure == nil)
            let stored = try storage.store.segments(from: .distantPast, to: .distantFuture)
            #expect(stored.map { [$0.start.timeIntervalSince(t0), $0.end.timeIntervalSince(t0)] } == [[100, 150], [150, 200], [200, 230]])
            #expect(stored.map(\.windowTitle) == ["After one", "After two", "After three"])
            for suffix in ["", "-wal"] {
                let bytes = (try? Data(contentsOf: URL(fileURLWithPath: storage.store.databaseURL.path + suffix))) ?? Data()
                #expect(bytes.range(of: Data("Morning plan".utf8)) == nil && bytes.range(of: Data("morning.example.com".utf8)) == nil, "activity.sqlite\(suffix)")
            }
        }
    }

    @Test func retractionsSeparatedByQueuedSavesStaySeparate() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 4, writesPerRetry: 8)
            // Flushed while the user was in fact away from 40.
            writes.save(segment("a", 0, 90, title: "One"), to: storage)
            storage.failSaves = true; storage.failDeletes = true
            writes.save(segment("a", 0, 40, title: "One"), to: storage)
            writes.retract(since: t0 + 40, until: t0 + 100, in: storage)
            writes.save(segment("b", 100, 150, title: "Two"), to: storage)
            writes.save(segment("c", 150, 200, title: "Three"), to: storage)
            #expect(writes.count == 4)
            // At capacity, the next segment is refused and idle from 230 is retracted after the queued saves.
            writes.save(segment("d", 200, 260, title: "Four"), to: storage)
            writes.save(segment("d", 200, 230, title: "Four"), to: storage)
            writes.retract(since: t0 + 230, until: t0 + 300, in: storage)
            #expect(writes.count == 5)
            #expect(writes.queue.filter { if case .retract = $0 { true } else { false } }.count == 2)

            storage.failSaves = false; storage.failDeletes = false
            let drained = writes.retry(storage)
            #expect(drained)
            let stored = try storage.store.segments(from: .distantPast, to: .distantFuture)
            #expect(stored.map { [$0.start.timeIntervalSince(t0), $0.end.timeIntervalSince(t0)] } == [[0, 40], [100, 150], [150, 200]])
        }
    }

    @Test func anAlternatingOutageNeverHoldsMoreThanCapacityPlusOne() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 3, writesPerRetry: 2)
            storage.failSaves = true; storage.failDeletes = true
            for index in 0..<300 {
                let at = Double(index) * 10
                if index % 3 == 2 { writes.retract(since: t0 + at + 5, until: t0 + at + 10, in: storage) }
                else { writes.save(segment("a", at, at + 5), to: storage) }
                #expect(writes.count <= 4)
            }
            #expect(writes.refusedSaves > 0)
        }
    }

    @Test func drainingAppliesTheWholeQueueInOrder() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 50, writesPerRetry: 8)
            storage.failSaves = true; storage.failDeletes = true
            for index in 0..<30 { writes.save(segment("a", Double(index) * 10, Double(index) * 10 + 5), to: storage) }
            writes.retract(since: t0 + 295, until: t0 + 400, in: storage)
            storage.failSaves = false; storage.failDeletes = false
            storage.calls = []
            // No new save: nothing is open when quitting, and the drain still applies everything queued.
            let drained = writes.drain(storage)
            #expect(drained && writes.isEmpty && writes.failure == nil)
            #expect(storage.calls == (0..<30).map { "save \($0 * 10)" } + ["delete 295", "checkpoint"])
            let stored = try storage.store.segmentCount()
            #expect(stored == 30)
        }
    }

    @Test func drainingStopsAtTheFirstFailureAndKeepsIt() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 50, writesPerRetry: 8)
            storage.failSaves = true; storage.failDeletes = true
            for index in 0..<12 { writes.save(segment("a", Double(index) * 10, Double(index) * 10 + 5), to: storage) }
            writes.retract(since: t0 + 200, until: t0 + 300, in: storage)
            for index in 30..<40 { writes.save(segment("a", Double(index) * 10, Double(index) * 10 + 5), to: storage) }
            storage.failSaves = false
            storage.calls = []
            let drained = writes.drain(storage)
            #expect(!drained && writes.failure != nil && writes.count == 11)
            #expect(storage.calls == (0..<12).map { "save \($0 * 10)" } + ["delete 200"])
            let stored = try storage.store.segmentCount()
            #expect(stored == 12)
        }
    }

    /// Stores rows, then queues failing retractions with the clock earlier than some of them, and recovers.
    private func recoverAfterRetractions(_ stored: [Segment], _ ranges: [(TimeInterval, TimeInterval)], reopen: Bool = false,
                                         failReads: Bool = false) throws -> (queue: [PendingWrites.Write], titles: [String?], blocks: [[Double]]) {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var storage = FlakyStorage(try ActivityStore(directory: directory))
        var writes = PendingWrites(capacity: 4, writesPerRetry: 8)
        for segment in stored { writes.save(segment, to: storage) }
        if reopen {
            storage = FlakyStorage(try ActivityStore(directory: directory))
            writes = PendingWrites(capacity: 4, writesPerRetry: 8)
        }
        storage.failDeletes = true; storage.failReads = failReads
        for (from, to) in ranges { writes.retract(since: t0 + from, until: t0 + to, in: storage) }
        let queue = Array(writes.queue)
        storage.failDeletes = false
        let drained = writes.drain(storage)
        #expect(drained && writes.failure == nil)
        let segments = try storage.store.segments(from: .distantPast, to: .distantFuture)
        let blocks = try storage.store.blocks(from: .distantPast, to: .distantFuture)
        return (queue, segments.map(\.windowTitle), blocks.map { [$0.start.timeIntervalSince(t0), $0.activeSeconds] })
    }

    @Test func retractionsAfterTheClockMovedBackNeverDeleteTheRowsBetweenThem() throws {
        // Recorded before the clock moved back to 220: rows inside both later ranges and one between them.
        let result = try recoverAfterRetractions(
            [segment("a", 110, 150, title: "Early"), segment("b", 250, 270, title: "Gap notes"), segment("c", 360, 400, title: "Late")],
            [(100, 220), (350, 470)])
        #expect(result.queue == [.retract(from: t0 + 100, to: t0 + 220), .retract(from: t0 + 350, to: t0 + 470)])
        #expect(result.titles == ["Gap notes"])
        #expect(result.blocks == [[180, 20]])
    }

    @Test func aRetractionBeforeTheQueuedOneNeverDeletesTheRowsBetweenThem() throws {
        // The later range is requested first, then the clock moves back and an earlier one follows.
        let result = try recoverAfterRetractions([segment("a", 630, 640, title: "Meeting notes")], [(655, 660), (595, 600)])
        #expect(result.queue.count == 2)
        #expect(result.titles == ["Meeting notes"])
        #expect(result.blocks == [[540, 10]])
    }

    @Test func aReopenedQueueLearnsTheLatestStoredEndBeforeMerging() throws {
        // The row was stored by an earlier run; this run's clock starts before it.
        let row = [segment("a", 620, 680, title: "Earlier run")]
        let reopened = try recoverAfterRetractions(row, [(500, 600), (700, 800)], reopen: true)
        #expect(reopened.queue == [.retract(from: t0 + 500, to: t0 + 600), .retract(from: t0 + 700, to: t0 + 800)])
        #expect(reopened.titles == ["Earlier run"])
        // Until storage reports its latest end, nothing is merged either.
        let unknown = try recoverAfterRetractions(row, [(500, 600), (700, 800)], reopen: true, failReads: true)
        #expect(unknown.queue.count == 2 && unknown.titles == ["Earlier run"])
        // Once the clock is past every stored row, adjacent retractions merge again.
        let later = try recoverAfterRetractions(row, [(700, 800), (900, 1_000)], reopen: true)
        #expect(later.queue == [.retract(from: t0 + 700, to: t0 + 1_000)] && later.titles == ["Earlier run"])
    }

    @Test func aSaveCoalescedWithTheQueuedOneKeepsTheContentStoredFirst() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 4, writesPerRetry: 8)
            storage.failSaves = true
            // After a clock step a new segment can start at the same second as the queued one; the store keeps the
            // first row's content and only moves its end, and recovery must too.
            writes.save(segment("a", 0, 60, title: "First"), to: storage)
            writes.save(segment("b", 0, 90, title: "Second"), to: storage)
            #expect(writes.count == 1)
            storage.failSaves = false
            let drained = writes.drain(storage)
            #expect(drained)
            let stored = try storage.store.segments(from: .distantPast, to: .distantFuture)
            #expect(stored.map(\.windowTitle) == ["First"] && stored.map { $0.end.timeIntervalSince(t0) } == [90])
        }
    }

    @Test func retractionsThatCannotMergeStopCaptureWhileItsClosingSaveFits() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 4, writesPerRetry: 2)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            writes.save(segment("a", 10_000, 10_060, title: "Before the step"), to: storage)
            storage.failSaves = true; storage.failDeletes = true
            // The clock keeps moving back below the stored row, so no retraction can merge; capture stops as soon as
            // the queue no longer accepts it, as CaptureSession does, and then makes neither saves nor idle retractions.
            var now = 9_000.0, captured = 0
            for step in 0..<100 where writes.acceptsCapture {
                writes.save(segment("b", now, now + 20, title: "Step \(step)"), to: storage)
                writes.retract(since: t0 + now + 20, until: t0 + now + 40, in: storage)
                captured += 1
                #expect(writes.count <= writes.capacity)
                now -= 100
            }
            #expect(!writes.acceptsCapture && writes.count == writes.capacity && captured == 2 && writes.refusedSaves == 0)
            writes.deleteDay(containing: t0 + now, calendar: utc, in: storage)
            #expect(writes.count == writes.capacity + 1 && writes.hasPendingDeletion)

            writes.deleteAll(in: storage)
            #expect(writes.queue == [.deleteAll] && writes.acceptsCapture)
            storage.failSaves = false; storage.failDeletes = false
            let drained = writes.retry(storage)
            #expect(drained && writes.failure == nil)
            let remaining = try storage.store.segmentCount()
            #expect(remaining == 0)
        }
    }

    @Test func captureResumesOnlyOnceTheNextSaveAndItsClosingSaveAreAdmitted() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 2, writesPerRetry: 1)
            writes.save(segment("a", 10_000, 10_060, title: "Kept"), to: storage)
            storage.failDeletes = true
            // Retractions after the clock moved back cannot merge, so they fill the queue past its capacity.
            for index in 0..<4 { writes.retract(since: t0 + Double(index) * 100, until: t0 + Double(index) * 100 + 50, in: storage) }
            #expect(!writes.acceptsCapture)
            storage.failDeletes = false
            // Recovering one write at a time, capture never resumes while a save, or the one closing it, would be refused.
            for _ in 0..<10 where !writes.isEmpty {
                writes.retry(storage)
                #expect(writes.acceptsCapture == writes.isEmpty)
            }
            #expect(writes.acceptsCapture && writes.failure == nil)
            for index in 0..<2 { writes.save(segment("b", 20_000 + Double(index) * 10, 20_005 + Double(index) * 10), to: storage) }
            #expect(writes.refusedSaves == 0)
            let titles = try storage.store.segments(from: .distantPast, to: .distantFuture).map(\.windowTitle)
            #expect(titles == ["Kept", nil, nil])
        }
    }

    @Test func appliedRemovalsLetCompactionResumeAfterTheClockMovedBack() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 8, writesPerRetry: 8)
            writes.save(segment("a", 10_000, 10_060, title: "Before the step"), to: storage)
            storage.failDeletes = true
            // Idle covering the stored row is queued, then the clock moves back: later retractions cannot merge.
            writes.retract(since: t0 + 10_000, until: t0 + 10_100, in: storage)
            writes.retract(since: t0 + 9_000, until: t0 + 9_050, in: storage)
            writes.retract(since: t0 + 9_100, until: t0 + 9_150, in: storage)
            #expect(writes.count == 3)
            // Once those are applied the stored maximum is read again, and adjacent retractions merge.
            storage.failDeletes = false
            writes.retry(storage)
            storage.failDeletes = true
            writes.retract(since: t0 + 9_200, until: t0 + 9_250, in: storage)
            writes.retract(since: t0 + 9_300, until: t0 + 9_350, in: storage)
            #expect(writes.queue == [.retract(from: t0 + 9_200, to: t0 + 9_350)])

            // A queued Delete All starts the bound afresh too, before it is applied.
            writes.save(segment("b", 11_000, 11_060), to: storage)
            writes.retract(since: t0 + 9_400, until: t0 + 9_450, in: storage)
            writes.deleteAll(in: storage)
            writes.retract(since: t0 + 9_500, until: t0 + 9_550, in: storage)
            writes.retract(since: t0 + 9_600, until: t0 + 9_650, in: storage)
            #expect(writes.queue == [.deleteAll, .retract(from: t0 + 9_500, to: t0 + 9_650)])
        }
    }

    /// Random sequences of captures, idle retractions, Delete Today, Delete All, failure windows, and retries end in
    /// exactly the state of applying every admitted write in request order; only saves refused at capacity are missing.
    @Test(arguments: 0..<24)
    func recoveryMatchesApplyingAdmittedWritesInOrder(seed: UInt64) throws {
        try checkRecoveryMatchesInOrder(seed: seed, clockSteps: false)
    }

    /// The same with the clock moving back, often across stored rows, and the app quitting and reopening its store, so
    /// rows can end after the request time and a fresh queue has to learn the stored maximum.
    @Test(arguments: 100..<140)
    func recoveryAcrossClockStepsAndReopenMatchesApplyingAdmittedWritesInOrder(seed: UInt64) throws {
        try checkRecoveryMatchesInOrder(seed: seed, clockSteps: true)
    }

    private func checkRecoveryMatchesInOrder(seed: UInt64, clockSteps: Bool) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var storage = FlakyStorage(try ActivityStore(directory: directory.appendingPathComponent("queued")))
        let reference = try ActivityStore(directory: directory.appendingPathComponent("reference"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var random = SplitMix(seed: seed)
        var writes = PendingWrites(capacity: 4, writesPerRetry: 2)
        // Starts ten minutes before a UTC midnight, so Delete Today sometimes covers the day before and sometimes not.
        var now = utc.startOfDay(for: t0).addingTimeInterval(86_400 - 600)
        var open: Segment?
        var recordingSince = now
        var titles = 0
        var deleteTodaysWhileFull = 0

        func save(_ segment: Segment) throws {
            let refused = writes.refusedSaves
            writes.save(segment, to: storage)
            if writes.refusedSaves == refused { try reference.save(segment) }
        }
        func endOpen(at end: Date) throws {
            guard var segment = open else { return }
            segment.end = max(segment.start, end)
            try save(segment)
            open = nil
        }

        for _ in 0..<(clockSteps ? 90 : 60) {
            now.addTimeInterval(Double(random.next(5...40)))
            if clockSteps, random.next(0...9) == 0 {
                // The recorder ends the open segment at its last sample before a clock step.
                if let segment = open { try endOpen(at: segment.end) }
                now.addTimeInterval(-Double(random.next(30...900)))
            }
            if clockSteps, random.next(0...29) == 0 {
                // Quitting drains the queue against working storage; the reopened store starts a fresh queue.
                try endOpen(at: now)
                storage.failSaves = false; storage.failDeletes = false; storage.failCheckpoints = false
                let drained = writes.drain(storage)
                #expect(drained)
                storage = FlakyStorage(try ActivityStore(directory: directory.appendingPathComponent("queued")))
                writes = PendingWrites(capacity: 4, writesPerRetry: 2)
            }
            if !writes.acceptsCapture {
                // CaptureSession stops recording while the queue does not accept capture.
                try endOpen(at: now)
            } else {
                deleteTodaysWhileFull = 0
            }
            let roll = random.next(0...99)
            switch !writes.acceptsCapture && roll < 70 ? 99 : roll {
            case 0..<55:
                if open == nil || random.next(0...2) == 0 {
                    try endOpen(at: now)
                    titles += 1
                    open = Segment(start: now, end: now, excluded: false, bundleID: "app\(titles % 3)", appName: "App", windowTitle: "Title \(titles)", url: nil)
                } else {
                    open?.end = now
                    try save(open!)
                }
            case 55..<70:
                let idleStart = max(recordingSince, now.addingTimeInterval(-Double(random.next(0...200))))
                try endOpen(at: idleStart)
                writes.retract(since: idleStart, until: now, in: storage)
                try reference.deleteData(from: idleStart, to: now)
                recordingSince = now
            case 70..<76:
                try endOpen(at: now)
                if !writes.acceptsCapture { deleteTodaysWhileFull += 1 }
                writes.deleteDay(containing: now, calendar: utc, in: storage)
                try reference.deleteData(from: utc.startOfDay(for: now), to: now)
            case 76..<79:
                try endOpen(at: now)
                writes.deleteAll(in: storage)
                try reference.deleteAll()
            case 79..<92:
                storage.failSaves = random.next(0...1) == 0
                storage.failDeletes = random.next(0...1) == 0
                storage.failCheckpoints = random.next(0...3) == 0
            default:
                writes.retry(storage)
            }
            #expect(writes.count <= writes.capacity + deleteTodaysWhileFull && writes.refusedSaves == 0)
        }
        try endOpen(at: now)
        storage.failSaves = false; storage.failDeletes = false; storage.failCheckpoints = false
        let drained = writes.drain(storage)
        #expect(drained)

        func rows(_ store: ActivityStore) throws -> [String] {
            try store.segments(from: .distantPast, to: .distantFuture).map {
                "\($0.start.timeIntervalSince1970) \($0.end.timeIntervalSince1970) \($0.bundleID ?? "") \($0.windowTitle ?? "")"
            } + store.blocks(from: .distantPast, to: .distantFuture).map {
                "block \($0.start.timeIntervalSince1970) \($0.activeSeconds) \($0.dominantTitle ?? "")"
            }
        }
        #expect(try rows(storage.store) == rows(reference))
    }
}

@Suite struct CaptureSessionTests {
    private let secret = segment("com.google.Chrome", 0, 0, title: "Secret plan", url: "https://secret.example.com/plan?q=1")

    @Test func offAndPauseOutrankABacklogAndTheBacklogOutranksTracking() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 3, writesPerRetry: 8)
            storage.failSaves = true
            writes.save(segment("a", 0, 10), to: storage)
            writes.save(segment("a", 20, 30), to: storage)
            var session = CaptureSession(storage: storage, maxSampleInterval: 30, writes: writes)
            session.update(CaptureConditions(), at: t0 + 40)
            #expect(session.state == .writesBacklogged)
            session.update(CaptureConditions(paused: true), at: t0 + 45)
            #expect(session.state == .paused)
            session.update(CaptureConditions(trackingOn: false, paused: true), at: t0 + 50)
            #expect(session.state == .off)
            // Leaving the pause into a queue that still has no room shows the backlog, not tracking.
            session.update(CaptureConditions(), at: t0 + 55)
            #expect(session.state == .writesBacklogged)
            storage.failSaves = false
            session.update(CaptureConditions(), at: t0 + 60)
            #expect(session.state == .recording && session.writes.isEmpty)
        }
    }

    @Test func idleTimeRecordedBeforeABacklogIsStillRetractedAfterIt() throws {
        try withStorage { storage in
            var session = CaptureSession(storage: storage, maxSampleInterval: 30, writes: PendingWrites(capacity: 3, writesPerRetry: 8))
            session.update(CaptureConditions(), at: t0)
            session.sample(content("notes", "Groceries"), at: t0)
            session.update(CaptureConditions(), at: t0 + 20)
            session.sample(content("notes", "Groceries"), at: t0 + 20)
            // The last input was at 20. A title change without input opens the secret page, and saves start failing.
            storage.failSaves = true
            session.update(CaptureConditions(secondsSinceInput: 20), at: t0 + 40)
            session.sample(secret, at: t0 + 40)
            session.update(CaptureConditions(secondsSinceInput: 40), at: t0 + 60)
            session.sample(secret, at: t0 + 60)
            // Flushing the page left no room for more capture: it stopped, with the closing save admitted.
            #expect(session.state == .writesBacklogged && session.open == nil && session.writes.refusedSaves == 0)
            storage.failSaves = false
            session.update(CaptureConditions(secondsSinceInput: 80), at: t0 + 100)
            #expect(session.state == .recording && session.writes.isEmpty)
            session.sample(secret, at: t0 + 100)
            session.update(CaptureConditions(secondsSinceInput: 130), at: t0 + 150)
            #expect(session.state == .idle)
            session.finish(at: t0 + 155)

            // Idle reaches back to the last input, across the backlog.
            let stored = try storage.store.segments(from: .distantPast, to: .distantFuture)
            #expect(stored.map { [$0.start.timeIntervalSince(t0), $0.end.timeIntervalSince(t0)] } == [[0, 20]])
            for suffix in ["", "-wal"] {
                let bytes = (try? Data(contentsOf: URL(fileURLWithPath: storage.store.databaseURL.path + suffix))) ?? Data()
                #expect(bytes.range(of: Data("Secret plan".utf8)) == nil && bytes.range(of: Data("secret.example.com".utf8)) == nil, "activity.sqlite\(suffix)")
            }
        }
    }

    @Test func aRelaunchWithAnEarlierClockNeverOverlapsStoredActivity() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do { try ActivityStore(directory: directory).save(segment("a", 0, 180, title: "Stored")) }
        // Relaunched with the clock 170 seconds earlier; the store cannot be read at first.
        let storage = FlakyStorage(try ActivityStore(directory: directory))
        storage.failReads = true
        var session = CaptureSession(storage: storage, maxSampleInterval: 30)
        session.update(CaptureConditions(), at: t0 + 10)
        session.sample(content("b", "Later"), at: t0 + 10)
        #expect(session.state == .storeUnavailable && session.readError != nil && session.open == nil)
        storage.failReads = false
        for second in stride(from: 15.0, through: 165, by: 15) {
            session.update(CaptureConditions(asleep: second > 100), at: t0 + second)
            session.sample(content("b", "Later"), at: t0 + second)
            #expect(session.state == .clockBehind && session.readError == nil && session.open == nil)
        }
        session.update(CaptureConditions(paused: true), at: t0 + 175)
        #expect(session.state == .paused)
        for second in stride(from: 180.0, through: 240, by: 15) {
            session.update(CaptureConditions(), at: t0 + second)
            session.sample(content("b", "Later"), at: t0 + second)
        }
        #expect(session.state == .recording)
        session.finish(at: t0 + 240)
        let stored = try storage.store.segments(from: .distantPast, to: .distantFuture)
        #expect(stored.map { [$0.start.timeIntervalSince(t0), $0.end.timeIntervalSince(t0)] } == [[0, 180], [180, 240]])
        let blocks = try storage.store.blocks(from: .distantPast, to: .distantFuture)
        #expect(blocks.map(\.activeSeconds) == [180, 60] && blocks.map(\.dominantTitle) == ["Stored", "Later"])
    }

    @Test func deleteAllLetsRecordingResumeWithTheClockBehindWhatItDeleted() throws {
        try withStorage { storage in
            try storage.store.save(segment("a", 1_000, 1_060, title: "Future"))
            var session = CaptureSession(storage: storage, maxSampleInterval: 30)
            session.update(CaptureConditions(), at: t0 + 10)
            #expect(session.state == .clockBehind)
            session.delete(all: true, at: t0 + 20, calendar: .current)
            for second in [25.0, 40, 55] {
                session.update(CaptureConditions(), at: t0 + second)
                session.sample(content("b", "After"), at: t0 + second)
            }
            #expect(session.state == .recording)
            session.finish(at: t0 + 55)
            let titles = try storage.store.segments(from: .distantPast, to: .distantFuture).map(\.windowTitle)
            #expect(titles == ["After"])
        }
    }

    /// A state the menu shows above sleep, lock, and a session switch.
    enum Mask: CaseIterable, Sendable { case backlog, clockBehind }
    /// A user choice or system state that interrupts tracking.
    enum Interruption: CaseIterable, Sendable {
        case asleep, locked, sessionInactive, paused, off

        func conditions(secondsSinceInput: TimeInterval = 0) -> CaptureConditions {
            CaptureConditions(trackingOn: self != .off, paused: self == .paused, asleep: self == .asleep, locked: self == .locked,
                              sessionInactive: self == .sessionInactive, secondsSinceInput: secondsSinceInput)
        }
    }

    private func stored(_ store: ActivityStore) throws -> [String] {
        try store.segments(from: .distantPast, to: .distantFuture).map {
            "\(Int($0.start.timeIntervalSince(t0)))-\(Int($0.end.timeIntervalSince(t0))) \($0.windowTitle ?? "")"
        }
    }

    /// Sleep, lock, or a session switch while the menu shows a backlog or a clock behind recorded activity still ends
    /// input-free time: idle after it never retracts what was recorded before it.
    @Test(arguments: Mask.allCases, [Interruption.asleep, .locked, .sessionInactive])
    func anInterruptionHiddenByTheMenuStateStillKeepsTheHistoryBeforeIt(mask: Mask, interruption: Interruption) throws {
        try withStorage { storage in
            var session = CaptureSession(storage: storage, maxSampleInterval: 30, writes: PendingWrites(capacity: 3))
            // The last input was at 0.
            for second in stride(from: 0.0, through: 55, by: 5) {
                session.update(CaptureConditions(secondsSinceInput: second), at: t0 + second)
                session.sample(content("a", "One"), at: t0 + second)
            }
            let interruptedAt: TimeInterval
            switch mask {
            case .backlog:
                // The title changes as writes start failing; the flush leaves no room, so capture stops at 60.
                storage.failSaves = true
                session.update(CaptureConditions(secondsSinceInput: 60), at: t0 + 60)
                session.sample(content("a", "Two"), at: t0 + 60)
                interruptedAt = 70
            case .clockBehind:
                // The clock steps back behind the open segment, which ends at its last sample.
                session.update(CaptureConditions(secondsSinceInput: 40), at: t0 + 40)
                interruptedAt = 45
            }
            session.update(interruption.conditions(secondsSinceInput: interruptedAt), at: t0 + interruptedAt)
            #expect(session.state == (mask == .backlog ? .writesBacklogged : .clockBehind))
            storage.failSaves = false
            for _ in 0..<3 { session.update(CaptureConditions(secondsSinceInput: 1_000), at: t0 + 1_000) }
            #expect(session.state == .idle && session.writes.isEmpty)
            // Without the outage the same flow also keeps 60-70 "Two"; the backlog stopped capture before it.
            let kept = try stored(storage.store)
            #expect(kept == [mask == .backlog ? "0-60 One" : "0-55 One"])
        }
    }

    /// Rows stored by an earlier run, ahead of a clock that was set back, belong to another clock frame: idle detected
    /// once the clock passes them retracts nothing of them, however long input stopped.
    @Test func idleAfterTheClockPassesStoredActivityNeverRetractsIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do { try ActivityStore(directory: directory).save(segment("a", 0, 180, title: "Stored")) }
        let store = try ActivityStore(directory: directory)
        var session = CaptureSession(storage: store, maxSampleInterval: 30)
        // Relaunched at 15 with the last input at 10.
        for second in stride(from: 15.0, through: 195, by: 15) {
            session.update(CaptureConditions(secondsSinceInput: second - 10), at: t0 + second)
            #expect(session.state == (second < 180 ? .clockBehind : .idle))
        }
        session.finish(at: t0 + 200)
        #expect(try stored(store) == ["0-180 Stored"])
        let blocks = try store.blocks(from: .distantPast, to: .distantFuture)
        #expect(blocks.map(\.activeSeconds) == [180] && blocks.map(\.dominantTitle) == ["Stored"])
    }

    /// A window read in flight when capture stops is never applied after it, whether or not a segment was open and
    /// whatever the menu shows meanwhile; only one read is in flight until the stale one is discarded.
    @Test(arguments: Interruption.allCases, [Mask?.none, .backlog, .clockBehind])
    func aReadInFlightIsVoidedByEveryStop(interruption: Interruption, mask: Mask?) throws {
        try withStorage { storage in
            let start: TimeInterval = mask == .clockBehind ? 100 : 0
            if mask == .clockBehind { try storage.store.save(segment("a", 0, 100, title: "Stored")) }
            var session = CaptureSession(storage: storage, maxSampleInterval: 30, writes: PendingWrites(capacity: 2))
            session.update(CaptureConditions(), at: t0 + start)
            #expect(session.state == .recording && session.open == nil)
            let begun = session.beginRead(of: 42, at: t0 + start)
            let ticket = try #require(begun)
            switch mask {
            case nil: break
            case .backlog:
                storage.failDeletes = true
                session.delete(all: false, at: t0 + start + 1, calendar: .current)
            case .clockBehind:
                session.update(CaptureConditions(), at: t0 + 50)
                #expect(session.state == .clockBehind)
            }
            let base = mask == .clockBehind ? 50.0 : start + 1
            session.update(interruption.conditions(), at: t0 + base + 1)
            session.update(CaptureConditions(), at: t0 + base + 2)
            storage.failDeletes = false
            let resumed = mask == .clockBehind ? 110.0 : base + 3
            session.update(CaptureConditions(), at: t0 + resumed)
            #expect(session.state == .recording && !session.isCurrent(ticket))
            #expect(session.beginRead(of: 42, at: t0 + resumed) == nil)
            session.complete(ticket, with: content("a", "Before"))
            #expect(session.open == nil)
            let next = session.beginRead(of: 42, at: t0 + resumed + 1)
            let fresh = try #require(next)
            session.complete(fresh, with: content("a", "After"))
            session.sample(content("a", "After"), at: t0 + resumed + 10)
            session.finish(at: t0 + resumed + 10)
            let after = "\(Int(resumed) + 1)-\(Int(resumed) + 10) After"
            let kept = try stored(storage.store)
            #expect(kept == (mask == .clockBehind ? ["0-100 Stored", after] : [after]))
        }
    }

    /// Turning tracking on, also from a pause, keeps the first window read and its start time, because the menu ends the
    /// segment before it changes the settings: each change samples at once, and ending the segment after the change that
    /// begins the read voids it. Turning tracking off in the same order still ends and saves the open segment.
    @Test(arguments: [false, true])
    func turningTrackingOnKeepsTheFirstRead(fromPause: Bool) throws {
        try withStorage { storage in
            var session = CaptureSession(storage: storage, maxSampleInterval: 30)
            var reads: [CaptureSequencer.Ticket] = []
            // What a settings change does in the app: it samples, and begins a window read while recording.
            func settingsChanged(_ conditions: CaptureConditions, at second: TimeInterval) {
                session.update(conditions, at: t0 + second)
                if let ticket = session.beginRead(of: 42, at: t0 + second) { reads.append(ticket) }
            }
            settingsChanged(CaptureConditions(trackingOn: false, paused: fromPause), at: 0)
            #expect(session.state == .off && reads.isEmpty)
            // Turn Tracking On: end the segment, then toggle tracking and clear the pause.
            session.endSegment(at: t0 + 10)
            settingsChanged(CaptureConditions(paused: fromPause), at: 10)
            settingsChanged(CaptureConditions(), at: 10)
            #expect(session.state == .recording && reads.count == 1)
            let first = try #require(reads.first)
            #expect(session.isCurrent(first))
            session.complete(first, with: content("a", "First"))
            #expect(session.open?.start == t0 + 10)
            session.sample(content("a", "First"), at: t0 + 40)
            // Turn Tracking Off in the same order.
            session.endSegment(at: t0 + 50)
            settingsChanged(CaptureConditions(trackingOn: false), at: 50)
            settingsChanged(CaptureConditions(trackingOn: false), at: 50)
            #expect(session.state == .off && session.open == nil && reads.count == 1)
            #expect(try stored(storage.store) == ["10-50 First"])
        }
    }

    /// The display sleeps 5 seconds after the last input, then the system sleeps and wakes without the display (a dark
    /// wake). Nothing is recorded and no read begins until the display wakes too, with or without input at that moment,
    /// and a read begun before the display slept stores nothing.
    @Test(arguments: [false, true])
    func aWakeWithoutTheDisplayRecordsNothingUntilTheDisplayWakes(inputAtWake: Bool) throws {
        try withStorage { storage in
            var session = CaptureSession(storage: storage, maxSampleInterval: 30)
            var signals = SleepSignals()
            var lastInput: TimeInterval = 0
            func update(_ second: TimeInterval) {
                session.update(CaptureConditions(asleep: signals.asleep, secondsSinceInput: second - lastInput), at: t0 + second)
            }
            for second in stride(from: 0.0, through: 45, by: 5) {
                lastInput = second
                update(second)
                session.sample(content("a", "Before"), at: t0 + second)
            }
            let begun = session.beginRead(of: 42, at: t0 + 45)
            let ticket = try #require(begun)
            signals.screensDidSleep()
            update(50)
            signals.systemWillSleep()
            update(55)
            signals.systemDidWake()
            for second in stride(from: 60.0, through: 95, by: 5) {
                update(second)
                session.sample(content("a", "During"), at: t0 + second)
                let read = session.beginRead(of: 42, at: t0 + second)
                #expect(session.state == .asleep && read == nil && session.open == nil, "at \(second)")
            }
            #expect(!session.isCurrent(ticket))
            session.complete(ticket, with: content("a", "During"))
            #expect(session.open == nil)
            signals.screensDidWake()
            for second in stride(from: 100.0, through: 160, by: 5) {
                if inputAtWake { lastInput = second }
                update(second)
                #expect(session.state == .recording)
                session.sample(content("a", "After"), at: t0 + second)
            }
            // Without input since 45, idle at 170 reaches back only to the display wake, never into what was recorded before.
            update(170)
            #expect(session.state == (inputAtWake ? .recording : .idle))
            session.finish(at: t0 + 170)
            #expect(try stored(storage.store) == (inputAtWake ? ["0-50 Before", "100-170 After"] : ["0-50 Before"]))
        }
    }

    /// Random outages, clock steps, relaunches, controls, system and display sleep (notified in either order, sometimes
    /// twice or unmatched), lock, session switches, window reads, input, and app switches: the session never tracks while
    /// a save would be refused, the queue stays within its bound, nothing it stores overlaps, no segment or read crosses
    /// an interruption, and idle never retracts what was recorded before the last resumption from one.
    @Test(arguments: 200..<240)
    func trackingAlwaysHasRoomAndStoredActivityNeverOverlaps(seed: UInt64) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var storage = FlakyStorage(try ActivityStore(directory: directory))
        var random = SplitMix(seed: seed)
        func newSession() -> CaptureSession {
            CaptureSession(storage: storage, maxSampleInterval: 30, writes: PendingWrites(capacity: 4, writesPerRetry: 1))
        }
        func recover() { storage.failSaves = false; storage.failDeletes = false; storage.failCheckpoints = false; storage.failReads = false }
        func toggle(_ on: Bool) -> Bool { on ? random.next(0...2) != 0 : random.next(0...19) == 0 }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var session = newSession()
        var now = t0, idle = 0.0, deleteTodaysWithoutRoom = 0
        var systemAsleep = false, displayAsleep = false, locked = false, sessionInactive = false
        var signals = SleepSignals()
        // Reads in flight, and whether an interruption has happened since each began.
        var reads: [(ticket: CaptureSequencer.Ticket, stale: Bool)] = []
        // The reference idle boundary: the last update without an interruption after one, from the conditions alone.
        var resumedAt = Date.distantPast, resumePending = true, steppedBack = false
        func checkOpen() {
            if let open = session.open, !steppedBack { #expect(open.start >= resumedAt) }
        }
        for _ in 0..<150 {
            let step = Double(random.next(1...40))
            now += step
            idle = random.next(0...3) == 0 ? 0 : idle + step
            if random.next(0...14) == 0 { now -= Double(random.next(30...600)); steppedBack = true }
            // macOS posts system and display sleep separately and in either order, sometimes twice, and can post a wake
            // without its sleep; the session sees only what the notifications leave in `signals`.
            let wasSystemAsleep = systemAsleep, wasDisplayAsleep = displayAsleep
            systemAsleep = toggle(systemAsleep)
            displayAsleep = toggle(displayAsleep)
            var notifications: [SleepSignalsTests.Event] = []
            if systemAsleep != wasSystemAsleep || random.next(0...9) == 0 {
                notifications.append(systemAsleep ? .systemWillSleep : .systemDidWake)
            }
            if displayAsleep != wasDisplayAsleep || random.next(0...9) == 0 {
                notifications.append(displayAsleep ? .screensDidSleep : .screensDidWake)
            }
            if random.next(0...1) == 0 { notifications.reverse() }
            for notification in notifications { notification.apply(to: &signals) }
            let asleep = systemAsleep || displayAsleep
            locked = toggle(locked)
            sessionInactive = toggle(sessionInactive)
            switch random.next(0...99) {
            case 0..<30: session.sample(content("app\(random.next(0...2))", "Title \(random.next(0...3))"), at: now)
            case 30..<38:
                if let ticket = session.beginRead(of: Int32(random.next(1...2)), at: now) { reads.append((ticket, false)) }
            case 38..<45:
                guard !reads.isEmpty else { break }
                let read = reads.removeFirst()
                let before = session.open
                session.complete(read.ticket, with: content("app\(random.next(0...2))", "Title \(random.next(0...3))"))
                if read.stale { #expect(session.open == before) }
            case 45..<55: session.foregroundChanged(at: now)
            case 55..<70:
                storage.failSaves = random.next(0...1) == 0
                storage.failDeletes = random.next(0...1) == 0
                storage.failCheckpoints = random.next(0...3) == 0
                storage.failReads = random.next(0...3) == 0
            case 70..<74:
                if !session.writes.acceptsCapture { deleteTodaysWithoutRoom += 1 }
                session.delete(all: false, at: now, calendar: utc)
            case 74..<76: session.delete(all: true, at: now, calendar: utc)
            case 76..<79:
                recover()
                session.finish(at: now)
                #expect(session.writes.isEmpty)
                storage = FlakyStorage(try ActivityStore(directory: directory))
                session = newSession()
                reads = []
                resumePending = true
            default: break
            }
            checkOpen()
            let conditions = CaptureConditions(trackingOn: random.next(0...19) != 0, paused: random.next(0...19) == 0, asleep: signals.asleep,
                                               locked: locked, sessionInactive: sessionInactive, secondsSinceInput: idle)
            // When nothing else is written, entering idle shows exactly what idle retracts.
            let healthy = !storage.failSaves && !storage.failDeletes && !storage.failCheckpoints && !storage.failReads
            let rowsBefore = healthy && session.writes.isEmpty && session.state != .idle
                ? try storage.store.segments(from: .distantPast, to: .distantFuture) : nil
            session.update(conditions, at: now)
            if !conditions.trackingOn || conditions.paused || asleep || locked || sessionInactive || session.state == .storeUnavailable {
                resumePending = true
                #expect(session.open == nil)
                for index in reads.indices {
                    #expect(!session.isCurrent(reads[index].ticket))
                    reads[index].stale = true
                }
            } else if resumePending {
                resumePending = false
                resumedAt = now
                steppedBack = false
            }
            if let rowsBefore, session.state == .idle {
                let rowsAfter = try storage.store.segments(from: .distantPast, to: .distantFuture)
                for row in rowsBefore where row.start < resumedAt {
                    let kept = rowsAfter.contains { $0.start == row.start && $0.end >= min(row.end, resumedAt) && $0.sameContent(as: row) }
                    #expect(kept, "idle at \(now.timeIntervalSince(t0)) retracted \(row.start.timeIntervalSince(t0)) before the resumption")
                }
            }
            if session.writes.acceptsCapture { deleteTodaysWithoutRoom = 0 }
            if session.state == .recording || session.state == .idle { #expect(session.writes.acceptsCapture) }
            #expect(session.writes.count <= session.writes.capacity + deleteTodaysWithoutRoom && session.writes.refusedSaves == 0)
        }
        recover()
        session.finish(at: now)
        #expect(session.writes.isEmpty)
        let segments = try storage.store.segments(from: .distantPast, to: .distantFuture)
        for (earlier, later) in zip(segments, segments.dropFirst()) { #expect(earlier.end <= later.start) }
        for block in try storage.store.blocks(from: .distantPast, to: .distantFuture) {
            #expect(block.activeSeconds + block.excludedSeconds <= Block.length)
        }
    }
}

/// A small seeded generator, so a failing sequence can be replayed.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next(_ range: ClosedRange<Int>) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return range.lowerBound + Int(value % UInt64(range.count))
    }
}
