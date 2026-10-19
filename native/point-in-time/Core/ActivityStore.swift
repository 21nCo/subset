import Foundation

/// The local source of truth for captured segments and their three-minute blocks. One SQLite database in a private
/// folder; nothing here touches the network.
///
/// Capture calls the store from the main actor. While another connection holds the write lock, a call waits about
/// 100 ms and throws; while another connection reads, a checkpoint throws at once (see `SQLiteConnection`). The write
/// that failed stays queued in `PendingWrites`, with its error shown, and is retried on the next sample.
public final class ActivityStore: @unchecked Sendable {
    /// The newest schema this build can read and write. Opening a newer database fails instead of guessing.
    public static let supportedSchemaVersion = 2

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
                try connection.execute("DELETE FROM segments; DELETE FROM blocks; DELETE FROM corrections;")
            }
            try connection.checkpointTruncatingWAL()
            try connection.execute("VACUUM;")
            try connection.checkpointTruncatingWAL()
        }
    }

    /// Copies the WAL into the database and truncates it. With `secure_delete` on, deleted rows are then gone from both
    /// files; capture calls this after every idle retraction and Delete Today. Throws at once, without waiting for the
    /// reader, when another connection's read kept the checkpoint from completing, so the removal stays queued and is
    /// retried.
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
            try connection.query("SELECT \(Self.blockColumns()) FROM blocks WHERE start >= ? AND start < ? ORDER BY start",
                                 [.real(Block.bucketStart(containing: from).timeIntervalSince1970), .real(to.timeIntervalSince1970)])
                .map { Self.block(from: $0) }
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

    // MARK: Classification

    /// Pending blocks that ended at or before `completedBy` and have something to send under `options` (recorded time
    /// and a dominant app that is not excluded), newest first.
    public func pendingBlocks(completedBy: Date, options: ClassificationOptions, limit: Int) throws -> [Block] {
        let (filter, bindings) = Self.pendingFilter(completedBy: completedBy, options: options)
        return try locked {
            try connection.query("SELECT \(Self.blockColumns()) FROM blocks WHERE \(filter) ORDER BY start DESC LIMIT ?",
                                 bindings + [.integer(Int64(limit))]).map { Self.block(from: $0) }
        }
    }

    /// The pending blocks `pendingBlocks` would send, the blocks that failed, and when a model last labeled a block.
    public func classificationSummary(completedBy: Date, options: ClassificationOptions) throws -> (pending: Int, failed: Int, lastClassified: Date?) {
        let (filter, bindings) = Self.pendingFilter(completedBy: completedBy, options: options)
        return try locked {
            let pending = try connection.query("SELECT COUNT(*) FROM blocks WHERE \(filter)", bindings).first?.first?.int ?? 0
            let row = try connection.query("""
                SELECT SUM(label_state = 'failed'), MAX(CASE WHEN label_state = 'classified' THEN classified_at END) FROM blocks
                """).first
            return (pending, row?[0].int ?? 0, row?[1].double.map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// Stores validated labels and counts a failed attempt for each rejected block, which becomes `failed` after
    /// `maxAttempts`, and returns how many labels were stored. Only a block that is still pending at the revision that
    /// was sent changes, so a correction made while the request ran is kept and a label is never stored for content
    /// capture changed since. Revisions are never reused, so a block that a deletion removed or changed, including one
    /// captured again at the same start, is never labeled by an answer about what was deleted.
    @discardableResult
    public func applyClassifications(_ accepted: [BlockClassification], rejected: [Block], provider: String, model: String,
                                     at date: Date, maxAttempts: Int = 5) throws -> Int {
        try locked {
            try connection.transaction {
                var stored = 0
                for result in accepted {
                    stored += try connection.query("""
                        UPDATE blocks SET label = ?, label_reason = ?, label_confidence = ?, label_source = ?, label_model = ?,
                            classified_at = ?, label_state = 'classified' WHERE start = ? AND revision = ? AND label_state = 'pending'
                        RETURNING start
                        """, [.text(result.label.rawValue), .text(result.reason), .real(result.confidence), .text(provider), .text(model),
                              .real(date.timeIntervalSince1970), .real(result.blockStart.timeIntervalSince1970),
                              .integer(Int64(result.revision))]).count
                }
                for block in rejected {
                    try connection.query("""
                        UPDATE blocks SET label_attempts = label_attempts + 1,
                            label_state = CASE WHEN label_attempts + 1 >= ? THEN 'failed' ELSE 'pending' END
                        WHERE start = ? AND revision = ? AND label_state = 'pending'
                        """, [.integer(Int64(maxAttempts)), .real(block.start.timeIntervalSince1970), .integer(Int64(block.revision))])
                }
                return stored
            }
        }
    }

    /// Makes every failed block pending again with a fresh attempt count (Retry Failed, a new provider or model, or a
    /// relaunch).
    public func requeueFailed() throws {
        try locked { _ = try connection.query("UPDATE blocks SET label_state = 'pending', label_attempts = 0 WHERE label_state = 'failed'") }
    }

    /// Records the user's label for a block and applies it at once. A later model result never replaces it.
    public func correct(blockStart: Date, to label: BlockLabel, note: String?, at date: Date) throws {
        let note = note.map { ClassificationRequest.cap($0.trimmingCharacters(in: .whitespacesAndNewlines), characters: ClassificationRequest.maxNoteCharacters) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let start = blockStart.timeIntervalSince1970
        try locked {
            try connection.transaction {
                guard let row = try connection.query("SELECT CASE WHEN label_state IN ('classified', 'corrected') THEN label END FROM blocks WHERE start = ?",
                                                     [.real(start)]).first else {
                    throw StoreError.sqlite("That block is no longer stored")
                }
                try connection.query("INSERT INTO corrections (block_start, previous_label, new_label, note, created_at) VALUES (?, ?, ?, ?, ?)",
                                     [.real(start), row[0], .text(label.rawValue), SQLValue(note), .real(date.timeIntervalSince1970)])
                try connection.query("""
                    UPDATE blocks SET label = ?, label_reason = ?, label_confidence = NULL, label_source = 'user', label_model = NULL,
                        classified_at = ?, label_state = 'corrected' WHERE start = ?
                    """, [.text(label.rawValue), SQLValue(note), .real(date.timeIntervalSince1970), .real(start)])
            }
        }
    }

    /// The most recent corrections whose block is still stored, newest first, each with the block's current content. Only
    /// a block's latest correction is returned, so a block corrected twice is not sent as two contradicting examples. With
    /// `options`, only corrections of blocks a request under them may send, and that ended by `completedBy`, count toward
    /// `limit`.
    public func recentCorrections(sendableUnder options: ClassificationOptions? = nil, completedBy: Date = .distantFuture,
                                  limit: Int = ClassificationRequest.maxCorrections) throws -> [LabelCorrection] {
        let excluded = options?.excludedBundleIDs.sorted() ?? []
        let sendable = options == nil ? "" : " AND b.active_seconds > 0 AND b.dominant_bundle_id IS NOT NULL AND b.start + ? <= ?"
            + (excluded.isEmpty ? "" : " AND b.dominant_bundle_id NOT IN (\(excluded.map { _ in "?" }.joined(separator: ", ")))")
        let settled: [SQLValue] = options == nil ? [] : [.real(Block.length), .real(completedBy.timeIntervalSince1970)]
        return try locked {
            try connection.query("""
                SELECT c.previous_label, c.new_label, c.note, c.created_at, \(Self.blockColumns(prefix: "b."))
                FROM corrections c JOIN blocks b ON b.start = c.block_start
                WHERE c.id = (SELECT d.id FROM corrections d WHERE d.block_start = c.block_start ORDER BY d.created_at DESC, d.id DESC LIMIT 1)\(sendable)
                ORDER BY c.created_at DESC, c.id DESC LIMIT ?
                """, settled + excluded.map { .text($0) } + [.integer(Int64(limit))]).compactMap { row in
                guard let new = row[1].string.flatMap(BlockLabel.init(rawValue:)) else { return nil }
                return LabelCorrection(block: Self.block(from: Array(row[4...])), previous: row[0].string.flatMap(BlockLabel.init(rawValue:)),
                                       new: new, note: row[2].string, at: Date(timeIntervalSince1970: row[3].double ?? 0))
            }
        }
    }

    // MARK: Internals

    private static func blockColumns(prefix: String = "") -> String {
        ["start", "active_seconds", "excluded_seconds", "apps_json", "dominant_bundle_id", "dominant_app_name", "dominant_title",
         "dominant_url_scheme", "dominant_url_host", "dominant_url_path", "label_state", "label", "label_reason", "label_confidence",
         "label_source", "label_model", "classified_at", "revision"].map { prefix + $0 }.joined(separator: ", ")
    }

    private static let contentColumns = ["active_seconds", "excluded_seconds", "apps_json", "dominant_bundle_id", "dominant_app_name",
                                         "dominant_title", "dominant_url_scheme", "dominant_url_host", "dominant_url_path"]

    private static func block(from row: [SQLValue]) -> Block {
        let apps = row[3].string.flatMap { try? JSONDecoder().decode([AppTime].self, from: Data($0.utf8)) } ?? []
        let url = row[7].string.flatMap { scheme in row[8].string.map { RedactedURL(scheme: scheme, host: $0, path: row[9].string ?? "/") } }
        // A pending or failed block may keep the columns of a label it had before its content changed; they are not its label.
        let state = row[10].string.flatMap(LabelState.init(rawValue:)) ?? .pending
        let labeling = state == .classified || state == .corrected
            ? BlockLabeling(state: state, label: row[11].string.flatMap(BlockLabel.init(rawValue:)), reason: row[12].string,
                            confidence: row[13].double, provider: row[14].string, model: row[15].string,
                            at: row[16].double.map(Date.init(timeIntervalSince1970:)))
            : BlockLabeling(state: state)
        return Block(start: Date(timeIntervalSince1970: row[0].double ?? 0), activeSeconds: row[1].double ?? 0,
                     excludedSeconds: row[2].double ?? 0, apps: apps, dominantBundleID: row[4].string,
                     dominantAppName: row[5].string, dominantTitle: row[6].string, dominantURL: url, labeling: labeling,
                     revision: row[17].int ?? 0)
    }

    private static func pendingFilter(completedBy: Date, options: ClassificationOptions) -> (String, [SQLValue]) {
        let excluded = options.excludedBundleIDs.sorted()
        let placeholders = excluded.map { _ in "?" }.joined(separator: ", ")
        let filter = "label_state = 'pending' AND active_seconds > 0 AND dominant_bundle_id IS NOT NULL AND start + ? <= ?"
            + (excluded.isEmpty ? "" : " AND dominant_bundle_id NOT IN (\(placeholders))")
        return (filter, [.real(Block.length), .real(completedBy.timeIntervalSince1970)] + excluded.map { .text($0) })
    }

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
    /// more than the data it touches. Rows whose bucket no longer holds any segment are deleted with their corrections.
    /// A new row, or one whose content changes, takes the next store-wide revision, which no row had before, even one deleted
    /// since; a changed row also becomes pending again unless the user corrected it: its label judged other content.
    private func rebuildBlocks(from: Date, to: Date) throws {
        let lower = Block.bucketStart(containing: from)
        let lastBucket = Block.bucketStart(containing: to)
        let upper = lastBucket < to ? lastBucket.addingTimeInterval(Block.length) : max(lastBucket, lower.addingTimeInterval(Block.length))
        // In start order, so the sums and the dominant segment come out the same however the rows are found.
        let overlapping = try connection.query("SELECT \(Self.segmentColumns) FROM segments WHERE start < ? AND end > ? ORDER BY start",
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
            try connection.query("DELETE FROM corrections WHERE block_start = ?", [row[0]])
        }
        for bucket in buckets.sorted() {
            let segments = overlapping.filter { $0.start < bucket.addingTimeInterval(Block.length) && $0.end > bucket }
            guard let block = Block.rollUp(start: bucket, segments: segments) else {
                try connection.query("DELETE FROM blocks WHERE start = ?", [.real(bucket.timeIntervalSince1970)])
                try connection.query("DELETE FROM corrections WHERE block_start = ?", [.real(bucket.timeIntervalSince1970)])
                continue
            }
            let apps = String(decoding: try Self.appsEncoder.encode(block.apps), as: UTF8.self)
            // Taken whether or not the row changes; a skipped number costs nothing.
            guard let revision = try connection.query("UPDATE block_revision SET value = value + 1 RETURNING value").first?.first else {
                throw StoreError.sqlite("The block revision counter is missing")
            }
            try connection.query("""
                INSERT INTO blocks (start, active_seconds, excluded_seconds, apps_json, dominant_bundle_id, dominant_app_name, dominant_title,
                                    dominant_url_scheme, dominant_url_host, dominant_url_path, revision)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(start) DO UPDATE SET active_seconds = excluded.active_seconds, excluded_seconds = excluded.excluded_seconds,
                    apps_json = excluded.apps_json, dominant_bundle_id = excluded.dominant_bundle_id, dominant_app_name = excluded.dominant_app_name,
                    dominant_title = excluded.dominant_title, dominant_url_scheme = excluded.dominant_url_scheme,
                    dominant_url_host = excluded.dominant_url_host, dominant_url_path = excluded.dominant_url_path,
                    revision = excluded.revision, label_attempts = 0,
                    label_state = CASE label_state WHEN 'corrected' THEN 'corrected' ELSE 'pending' END,
                    \(Self.labelColumns.map { "\($0) = CASE label_state WHEN 'corrected' THEN \($0) END" }.joined(separator: ", "))
                WHERE (\(Self.contentColumns.map { "blocks." + $0 }.joined(separator: ", ")))
                    IS NOT (\(Self.contentColumns.map { "excluded." + $0 }.joined(separator: ", ")))
                """, [.real(bucket.timeIntervalSince1970), .real(block.activeSeconds), .real(block.excludedSeconds), .text(apps),
                      SQLValue(block.dominantBundleID), SQLValue(block.dominantAppName), SQLValue(block.dominantTitle),
                      SQLValue(block.dominantURL?.scheme), SQLValue(block.dominantURL?.host), SQLValue(block.dominantURL?.path), revision])
        }
    }

    /// A model's label for content that has since changed is cleared with it; the user's correction is kept.
    private static let labelColumns = ["label", "label_reason", "label_confidence", "label_source", "label_model", "classified_at"]

    /// Sorted keys, so the same apps always encode to the same text and an unchanged block keeps its revision.
    private static let appsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Forward-only migrations, applied in order and recorded in `schema_version`.
    static let migrations: [Int: String] = [
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
        """,
        // Classification state and content revision per block, the store-wide revision counter, and the user's corrections.
        // Existing blocks start pending.
        2: """
        ALTER TABLE blocks ADD COLUMN label_state TEXT NOT NULL DEFAULT 'pending';
        ALTER TABLE blocks ADD COLUMN label_model TEXT;
        ALTER TABLE blocks ADD COLUMN label_attempts INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE blocks ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
        CREATE INDEX blocks_label_state ON blocks (label_state, start);
        CREATE TABLE block_revision (value INTEGER NOT NULL);
        INSERT INTO block_revision (value) VALUES (0);
        CREATE TABLE corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT, block_start REAL NOT NULL, previous_label TEXT, new_label TEXT NOT NULL,
            note TEXT, created_at REAL NOT NULL
        );
        CREATE INDEX corrections_block ON corrections (block_start);
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
