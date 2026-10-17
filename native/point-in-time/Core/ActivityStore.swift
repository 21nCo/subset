import Foundation

/// The local source of truth for captured segments and their three-minute blocks. One SQLite database in a private
/// folder; nothing here touches the network.
public final class ActivityStore: @unchecked Sendable {
    /// The newest schema this build can read and write. Opening a newer database fails instead of guessing.
    public static let supportedSchemaVersion = 1

    public let databaseURL: URL
    private let connection: SQLiteConnection
    private let lock = NSLock()

    /// `~/Library/Application Support/pointInTime`.
    public static func defaultDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.filesystem("Application Support is unavailable")
        }
        return base.appendingPathComponent("pointInTime", isDirectory: true)
    }

    /// Opens or creates `activity.sqlite` in `directory`, which is created with mode 0700. The database is mode 0600;
    /// SQLite gives its WAL and shared-memory files the same mode. A database written by a newer schema is refused
    /// without being changed.
    public convenience init(directory: URL) throws {
        try self.init(directory: directory, beforeMigrating: {})
    }

    /// `beforeMigrating` runs after the read-only schema check, so tests can change the database in between.
    init(directory: URL, beforeMigrating: () throws -> Void) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw StoreError.filesystem(error.localizedDescription)
        }
        databaseURL = directory.appendingPathComponent("activity.sqlite")
        if !fileManager.fileExists(atPath: databaseURL.path) {
            guard fileManager.createFile(atPath: databaseURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw StoreError.filesystem("Could not create the database file")
            }
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        } catch {
            throw StoreError.filesystem(error.localizedDescription)
        }
        // A newer database is refused before a read-write connection exists: closing that connection could checkpoint
        // the newer database's WAL into its file.
        try Self.refuseNewerSchema(at: databaseURL.path)
        connection = try SQLiteConnection(path: databaseURL.path)
        try connection.execute("PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON;")
        try beforeMigrating()
        // The version is checked again under the write lock, so one that advanced since the check above is refused too,
        // and only then does the journal mode change.
        try migrate()
        try connection.execute("PRAGMA journal_mode=WAL;")
    }

    public func schemaVersion() throws -> Int {
        try locked { try Self.storedVersion(connection) }
    }

    // MARK: Writing

    /// Inserts a segment, or moves the end of the stored one with the same start, and rebuilds the blocks between its
    /// old and new end. An empty segment removes the stored one: the recorder returns it when a gap (idle) began at or
    /// before the segment's start, so time that was flushed earlier is retracted.
    public func save(_ segment: Segment) throws {
        let start = segment.start.timeIntervalSince1970, end = segment.end.timeIntervalSince1970
        try locked {
            try connection.transaction {
                let previousEnd = try connection.query("SELECT end FROM segments WHERE start = ?", [.real(start)]).first?.first?.double
                guard segment.duration > 0 else {
                    guard let previousEnd else { return }
                    try connection.query("DELETE FROM segments WHERE start = ?", [.real(start)])
                    try rebuildBlocks(from: segment.start, to: Date(timeIntervalSince1970: previousEnd))
                    return
                }
                try connection.query("INSERT INTO segments (\(Self.segmentColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(start) DO UPDATE SET end = excluded.end",
                                     Self.bindings(for: segment))
                // A shorter end (idle retracting flushed time) must clear the buckets past it as well.
                let from = previousEnd.map { Date(timeIntervalSince1970: min($0, end)) } ?? segment.start
                let to = Date(timeIntervalSince1970: max(previousEnd ?? end, end))
                try rebuildBlocks(from: from, to: to)
            }
        }
    }

    /// Deletes everything recorded in `[from, to)`. A segment that crosses a boundary keeps only its part outside the
    /// range, so deleting today leaves yesterday's evening intact.
    public func deleteData(from: Date, to: Date) throws {
        guard to > from else { return }
        let lower = from.timeIntervalSince1970, upper = to.timeIntervalSince1970
        try locked {
            try connection.transaction {
                // A segment spanning the whole range splits into its parts before and after it.
                let spanning = try connection.query("SELECT \(Self.segmentColumns) FROM segments WHERE start < ? AND end > ?", [.real(lower), .real(upper)])
                try connection.query("DELETE FROM segments WHERE start >= ? AND end <= ?", [.real(lower), .real(upper)])
                try connection.query("UPDATE segments SET end = ? WHERE start < ? AND end > ? AND end <= ?", [.real(lower), .real(lower), .real(lower), .real(upper)])
                for row in spanning {
                    var tail = Self.segment(from: row)
                    tail.start = to
                    try connection.query("UPDATE segments SET end = ? WHERE start = ?", [.real(lower), row[0]])
                    try insert(tail)
                }
                for row in try connection.query("SELECT \(Self.segmentColumns) FROM segments WHERE start >= ? AND start < ? AND end > ?", [.real(lower), .real(upper), .real(upper)]) {
                    var tail = Self.segment(from: row)
                    tail.start = to
                    try connection.query("DELETE FROM segments WHERE start = ?", [row[0]])
                    try insert(tail)
                }
                try rebuildBlocks(from: from, to: to)
            }
        }
    }

    /// Deletes all captured data and compacts the file so deleted pages do not linger in the database or its WAL. Throws
    /// when a checkpoint could not complete (see `checkpoint`); running it again finishes the job.
    public func deleteAll() throws {
        try locked {
            try connection.transaction {
                try connection.execute("DELETE FROM segments; DELETE FROM blocks;")
            }
            try connection.checkpointTruncatingWAL()
            try connection.execute("VACUUM;")
            try connection.checkpointTruncatingWAL()
        }
    }

    /// Copies the WAL into the database and truncates it. With `secure_delete` on, deleted rows are then gone from both
    /// files; capture calls this after every idle retraction and Delete Today. Throws when another connection's read
    /// kept the checkpoint from completing, so the removal stays queued and is retried.
    public func checkpoint() throws {
        try locked { try connection.checkpointTruncatingWAL() }
    }

    // MARK: Reading

    public func segments(from: Date, to: Date) throws -> [Segment] {
        guard to > from else { return [] }
        return try locked {
            try connection.query("SELECT \(Self.segmentColumns) FROM segments WHERE start < ? AND end > ? ORDER BY start",
                                 [.real(to.timeIntervalSince1970), .real(from.timeIntervalSince1970)]).map(Self.segment(from:))
        }
    }

    public func blocks(from: Date, to: Date) throws -> [Block] {
        guard to > from else { return [] }
        return try locked {
            try connection.query("""
                SELECT start, active_seconds, excluded_seconds, apps_json, dominant_bundle_id, dominant_app_name, dominant_title,
                       dominant_url_scheme, dominant_url_host, dominant_url_path
                FROM blocks WHERE start >= ? AND start < ? ORDER BY start
                """, [.real(Block.bucketStart(containing: from).timeIntervalSince1970), .real(to.timeIntervalSince1970)]).map { row in
                let apps = row[3].string.flatMap { try? JSONDecoder().decode([AppTime].self, from: Data($0.utf8)) } ?? []
                let url = row[7].string.flatMap { scheme in row[8].string.map { RedactedURL(scheme: scheme, host: $0, path: row[9].string ?? "/") } }
                return Block(start: Date(timeIntervalSince1970: row[0].double ?? 0), activeSeconds: row[1].double ?? 0,
                             excludedSeconds: row[2].double ?? 0, apps: apps, dominantBundleID: row[4].string,
                             dominantAppName: row[5].string, dominantTitle: row[6].string, dominantURL: url)
            }
        }
    }

    /// The latest end of any stored segment, or nil when none is stored.
    public func latestSegmentEnd() throws -> Date? {
        try locked {
            try connection.query("SELECT MAX(end) FROM segments").first?.first?.double.map(Date.init(timeIntervalSince1970:))
        }
    }

    public func segmentCount() throws -> Int {
        try locked { try connection.query("SELECT COUNT(*) FROM segments").first?.first?.int ?? 0 }
    }

    // MARK: Internals

    private static let segmentColumns = "start, end, excluded, bundle_id, app_name, window_title, url_scheme, url_host, url_path"

    private static func segment(from row: [SQLValue]) -> Segment {
        let url = row[6].string.flatMap { scheme in row[7].string.map { RedactedURL(scheme: scheme, host: $0, path: row[8].string ?? "/") } }
        return Segment(start: Date(timeIntervalSince1970: row[0].double ?? 0), end: Date(timeIntervalSince1970: row[1].double ?? 0),
                       excluded: row[2].int == 1, bundleID: row[3].string, appName: row[4].string, windowTitle: row[5].string, url: url)
    }

    private func insert(_ segment: Segment) throws {
        guard segment.duration > 0 else { return }
        try connection.query("INSERT OR REPLACE INTO segments (\(Self.segmentColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", Self.bindings(for: segment))
    }

    /// The values for `segmentColumns`, used by every segment write. The text goes through `Segment`'s bounds again, which
    /// leaves a segment's own text unchanged, so the store never writes more than those bounds allow.
    private static func bindings(for segment: Segment) -> [SQLValue] {
        let url = segment.url.map { RedactedURL(scheme: $0.scheme, host: $0.host, path: $0.path) }
        return [.real(segment.start.timeIntervalSince1970), .real(segment.end.timeIntervalSince1970), .integer(segment.excluded ? 1 : 0),
                SQLValue(Segment.boundedIdentity(segment.bundleID)), SQLValue(Segment.boundedIdentity(segment.appName)),
                SQLValue(Segment.boundedTitle(segment.windowTitle)), SQLValue(url?.scheme), SQLValue(url?.host), SQLValue(url?.path)]
    }

    /// Recomputes every bucket touched by `[from, to)` from the stored segments. Only buckets that a stored segment or
    /// block row actually occupies are visited, so an unbounded range (Delete Today passes `.distantFuture`) costs no
    /// more than the data it touches. Rows whose bucket no longer holds any segment are deleted; the others have their
    /// capture columns replaced and keep the reserved classification columns.
    private func rebuildBlocks(from: Date, to: Date) throws {
        let lower = Block.bucketStart(containing: from)
        let lastBucket = Block.bucketStart(containing: to)
        let upper = lastBucket < to ? lastBucket.addingTimeInterval(Block.length) : max(lastBucket, lower.addingTimeInterval(Block.length))
        let overlapping = try connection.query("SELECT \(Self.segmentColumns) FROM segments WHERE start < ? AND end > ?",
                                               [.real(upper.timeIntervalSince1970), .real(lower.timeIntervalSince1970)]).map(Self.segment(from:))
        var buckets = Set<Date>()
        for segment in overlapping {
            let start = max(segment.start, lower), end = min(segment.end, upper)
            if end > start { buckets.formUnion(Block.bucketStarts(from: start, to: end)) }
        }
        let stored = try connection.query("SELECT start FROM blocks WHERE start >= ? AND start < ?",
                                          [.real(lower.timeIntervalSince1970), .real(upper.timeIntervalSince1970)])
        for row in stored where !buckets.contains(Date(timeIntervalSince1970: row[0].double ?? 0)) {
            try connection.query("DELETE FROM blocks WHERE start = ?", [row[0]])
        }
        for bucket in buckets.sorted() {
            let segments = overlapping.filter { $0.start < bucket.addingTimeInterval(Block.length) && $0.end > bucket }
            guard let block = Block.rollUp(start: bucket, segments: segments) else {
                try connection.query("DELETE FROM blocks WHERE start = ?", [.real(bucket.timeIntervalSince1970)])
                continue
            }
            let apps = String(decoding: try JSONEncoder().encode(block.apps), as: UTF8.self)
            try connection.query("""
                INSERT INTO blocks (start, active_seconds, excluded_seconds, apps_json, dominant_bundle_id, dominant_app_name, dominant_title,
                                    dominant_url_scheme, dominant_url_host, dominant_url_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(start) DO UPDATE SET active_seconds = excluded.active_seconds, excluded_seconds = excluded.excluded_seconds,
                    apps_json = excluded.apps_json, dominant_bundle_id = excluded.dominant_bundle_id, dominant_app_name = excluded.dominant_app_name,
                    dominant_title = excluded.dominant_title, dominant_url_scheme = excluded.dominant_url_scheme,
                    dominant_url_host = excluded.dominant_url_host, dominant_url_path = excluded.dominant_url_path
                """, [.real(bucket.timeIntervalSince1970), .real(block.activeSeconds), .real(block.excludedSeconds), .text(apps),
                      SQLValue(block.dominantBundleID), SQLValue(block.dominantAppName), SQLValue(block.dominantTitle),
                      SQLValue(block.dominantURL?.scheme), SQLValue(block.dominantURL?.host), SQLValue(block.dominantURL?.path)])
        }
    }

    /// Forward-only migrations, applied in order and recorded in `schema_version`.
    private static let migrations: [Int: String] = [
        1: """
        CREATE TABLE segments (
            start REAL PRIMARY KEY, end REAL NOT NULL, excluded INTEGER NOT NULL DEFAULT 0,
            bundle_id TEXT, app_name TEXT, window_title TEXT, url_scheme TEXT, url_host TEXT, url_path TEXT,
            CHECK (end >= start)
        );
        CREATE INDEX segments_end ON segments (end);
        CREATE TABLE blocks (
            start REAL PRIMARY KEY, active_seconds REAL NOT NULL, excluded_seconds REAL NOT NULL, apps_json TEXT NOT NULL,
            dominant_bundle_id TEXT, dominant_app_name TEXT, dominant_title TEXT,
            dominant_url_scheme TEXT, dominant_url_host TEXT, dominant_url_path TEXT,
            -- Reserved for classification; capture never writes these.
            label TEXT, label_reason TEXT, label_confidence REAL, label_source TEXT, classified_at REAL
        );
        """
    ]

    /// Reads the schema version through a read-only connection, which changes no file, and refuses a newer one. A WAL
    /// database without a WAL file, as a store closed before its first write is left, has nothing outside its main file
    /// and is read from that alone. One with a WAL but no -shm file is read with a writable -shm instead, which SQLite
    /// may create, while the database and its WAL stay unchanged.
    private static func refuseNewerSchema(at path: String) throws {
        let version: Int
        do {
            version = try storedVersion(SQLiteConnection(readingOnly: path, .sharedMemoryReadOnly))
        } catch {
            let hasWAL = FileManager.default.fileExists(atPath: path + "-wal")
            version = try storedVersion(SQLiteConnection(readingOnly: path, hasWAL ? .sharedMemoryWritable : .withoutWAL))
        }
        try refuse(newerThanSupported: version)
    }

    /// The schema version recorded in the database; one without a `schema_version` table is version 0.
    private static func storedVersion(_ connection: SQLiteConnection) throws -> Int {
        guard try !connection.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_version'").isEmpty else { return 0 }
        return try connection.query("SELECT MAX(version) FROM schema_version").first?.first?.int ?? 0
    }

    private static func refuse(newerThanSupported version: Int) throws {
        guard version <= supportedSchemaVersion else {
            throw StoreError.newerSchema(found: version, supported: supportedSchemaVersion)
        }
    }

    /// Reads the version and applies every missing migration in one write transaction, so nothing changes between the
    /// check and the migrations, and a newer version is refused before anything is written.
    private func migrate() throws {
        try connection.transaction {
            let current = try Self.storedVersion(connection)
            try Self.refuse(newerThanSupported: current)
            try connection.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)")
            for version in (current + 1)...max(current + 1, Self.supportedSchemaVersion) where version <= Self.supportedSchemaVersion {
                guard let sql = Self.migrations[version] else { continue }
                try connection.execute(sql)
                try connection.query("INSERT INTO schema_version (version, applied_at) VALUES (?, ?)", [.integer(Int64(version)), .real(Date().timeIntervalSince1970)])
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
