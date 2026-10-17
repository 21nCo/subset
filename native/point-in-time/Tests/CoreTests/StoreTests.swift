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
            INSERT INTO schema_version VALUES (2, 0);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        #expect(throws: StoreError.newerSchema(found: 2, supported: 1)) { try ActivityStore(directory: directory) }

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
            INSERT INTO schema_version VALUES (1, 0);
            PRAGMA wal_checkpoint(TRUNCATE);
            PRAGMA wal_autocheckpoint=0;
            INSERT INTO schema_version VALUES (2, 0);
            CREATE TABLE newer (value TEXT);
            """, nil, nil, nil) == SQLITE_OK)
        let suffixes = keepSharedMemory ? ["", "-wal", "-shm"] : ["", "-wal"]
        let crashed = try suffixes.map { try Data(contentsOf: URL(fileURLWithPath: path + $0)) }
        sqlite3_close(db)
        for (suffix, bytes) in zip(suffixes, crashed) { try bytes.write(to: URL(fileURLWithPath: path + suffix)) }
        try? FileManager.default.removeItem(atPath: path + (keepSharedMemory ? "-journal" : "-shm"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path + "-wal")).count > 0)

        #expect(throws: StoreError.newerSchema(found: 2, supported: 1)) { try ActivityStore(directory: directory) }

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
            INSERT INTO schema_version VALUES (2, 0);
            PRAGMA wal_checkpoint(TRUNCATE);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(before[18] == 2 && before[19] == 2)

        #expect(throws: StoreError.newerSchema(found: 2, supported: 1)) { try ActivityStore(directory: directory) }

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
        #expect(throws: StoreError.newerSchema(found: 2, supported: 1)) {
            try ActivityStore(directory: directory) {
                // Another, newer copy of the app migrates the database after the read-only check passed.
                var db: OpaquePointer?
                #expect(sqlite3_open(path, &db) == SQLITE_OK)
                #expect(sqlite3_exec(db, "INSERT INTO schema_version VALUES (2, 0)", nil, nil, nil) == SQLITE_OK)
                sqlite3_close(db)
                advanced = contents()
            }
        }
        #expect(advanced.contains("version 2") && advanced.contains { $0.hasPrefix("segment ") })
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
    func deleteAll() throws { calls.append("deleteAll"); try fail(failDeletes); try store.deleteAll() }
    func latestSegmentEnd() throws -> Date? { try fail(failReads); return try store.latestSegmentEnd() }
}

@Suite struct PendingWritesTests {
    private func withStorage(_ body: (FlakyStorage) throws -> Void) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(FlakyStorage(try ActivityStore(directory: directory)))
    }

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

    @Test func retractionsThatCannotMergeStopCaptureAtTheHardLimit() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 4, writesPerRetry: 2)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            writes.save(segment("a", 10_000, 10_060, title: "Before the step"), to: storage)
            storage.failSaves = true; storage.failDeletes = true
            // The clock keeps moving back below the stored row, so no retraction can merge; capture stops when full,
            // as CaptureController does, and then makes neither saves nor idle retractions.
            var now = 9_000.0, captured = 0
            for step in 0..<100 {
                if !writes.isFull {
                    writes.save(segment("b", now, now + 20, title: "Step \(step)"), to: storage)
                    writes.retract(since: t0 + now + 20, until: t0 + now + 40, in: storage)
                    captured += 1
                }
                #expect(writes.count <= writes.hardLimit)
                now -= 100
            }
            #expect(writes.isFull && writes.count == writes.hardLimit && captured < 100)
            writes.deleteDay(containing: t0 + now, calendar: utc, in: storage)
            #expect(writes.count == writes.hardLimit + 1 && writes.hasPendingDeletion)

            writes.deleteAll(in: storage)
            #expect(writes.queue == [.deleteAll] && !writes.isFull)
            storage.failSaves = false; storage.failDeletes = false
            let drained = writes.retry(storage)
            #expect(drained && writes.failure == nil)
            let remaining = try storage.store.segmentCount()
            #expect(remaining == 0)
        }
    }

    @Test func recoveryFromTheHardLimitResumesCapture() throws {
        try withStorage { storage in
            var writes = PendingWrites(capacity: 2, writesPerRetry: 1)
            writes.save(segment("a", 10_000, 10_060, title: "Kept"), to: storage)
            storage.failDeletes = true
            for index in 0..<4 { writes.retract(since: t0 + Double(index) * 100, until: t0 + Double(index) * 100 + 50, in: storage) }
            #expect(writes.isFull)
            storage.failDeletes = false
            writes.retry(storage)
            #expect(!writes.isFull && writes.failure != nil)
            let drained = writes.drain(storage)
            #expect(drained && writes.failure == nil)
            let titles = try storage.store.segments(from: .distantPast, to: .distantFuture).map(\.windowTitle)
            #expect(titles == ["Kept"])
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
            if writes.isFull {
                // CaptureController stops recording while the queue is full.
                try endOpen(at: now)
            } else {
                deleteTodaysWhileFull = 0
            }
            let roll = random.next(0...99)
            switch writes.isFull && roll < 70 ? 99 : roll {
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
                if writes.isFull { deleteTodaysWhileFull += 1 }
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
            #expect(writes.count <= (clockSteps ? writes.hardLimit + deleteTodaysWhileFull : writes.capacity + 1))
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
