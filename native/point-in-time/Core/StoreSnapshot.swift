import Foundation

/// Why the status command could not read the store. Messages never include captured content.
public enum StoreReadFailure: Error, Equatable, Sendable {
    /// No `activity.sqlite` in the folder: pointInTime has not recorded on this Mac, or the data was removed.
    case missing
    /// Written by a newer pointInTime than this command reads.
    case newerSchema(found: Int, supported: Int)
    /// Not yet migrated to the schema this command reads; the app migrates it when it opens.
    case olderSchema(found: Int, supported: Int)
    /// Another connection held a lock for longer than the command waits.
    case locked(String)
    /// Any other open or read failure: permissions, a damaged file, an unexpected layout.
    case unreadable(String)

    public var message: String {
        switch self {
        case .missing: "No activity store was found. pointInTime has not recorded anything on this Mac yet."
        case .newerSchema(let found, let supported):
            "The activity store uses schema \(found); this command reads up to \(supported). Update pointInTime."
        case .olderSchema(let found, let supported):
            "The activity store uses schema \(found); this command reads \(supported). Open pointInTime once to update it."
        case .locked(let detail): "The activity store is locked by another process (\(detail)). Try again."
        case .unreadable(let detail): "The activity store could not be read: \(detail)"
        }
    }
}

/// What the status command reads from the store, all in one read transaction so the parts agree with each other.
public struct StoreSnapshot: Equatable, Sendable {
    public var schemaVersion: Int
    /// Blocks starting in the range that was asked for, in start order.
    public var blocks: [Block]
    /// The latest end of any stored segment.
    public var latestSegmentEnd: Date?
    /// When a model last labeled any block.
    public var lastClassified: Date?

    /// How long the command waits for another connection's lock, 500 ms. A reader in WAL mode waits only while the
    /// store is being recovered or a connection holds it exclusively.
    public static let lockWaitNanoseconds: UInt64 = 500_000_000

    /// Reads `activity.sqlite` in `directory` without changing it. The connection is read-only (`SQLITE_OPEN_READONLY`),
    /// so it cannot write, checkpoint, or remove the WAL, and it reads the app's writes through the WAL while the app is
    /// running. As in `ActivityStore`'s schema check, the WAL index is opened read-only when it can be; a WAL whose index
    /// is missing or cannot be used read-only is read with a writable index, which SQLite may create or rebuild beside
    /// it; and a store with no WAL is read from its main file alone, which creates nothing. If a WAL appears during that
    /// last read (the app started writing), the read is repeated through the WAL, also when that read failed. This
    /// relies on SQLite keeping the WAL once a writer closes, as the macOS library does, so a WAL written during the read
    /// is still there to be noticed afterwards.
    public static func read(directory: URL, blocksFrom: Date, to: Date, lockWait: UInt64 = lockWaitNanoseconds) throws(StoreReadFailure) -> StoreSnapshot {
        let path = directory.appendingPathComponent("activity.sqlite").path
        switch entry(at: path) {
        case .present: break
        case .absent: throw .missing
        case .unknown(let code):
            throw .unreadable("its location could not be checked (\(String(cString: strerror(code)))).")
        }
        do {
            return try readAnyMode(path: path, from: blocksFrom, to: to, lockWait: lockWait)
        } catch let failure as StoreReadFailure {
            throw failure
        } catch StoreError.busy(let detail) {
            throw .locked(detail)
        } catch {
            throw .unreadable(String(describing: error))
        }
    }

    enum Entry: Equatable {
        case present, absent
        /// `stat` failed for a reason other than absence, such as a folder without search permission.
        case unknown(Int32)
    }

    /// Whether `path` exists. Unlike `FileManager.fileExists`, which reports false for any failure, only `ENOENT` and
    /// `ENOTDIR` mean absent, so a store that cannot be reached is not reported as one that was never recorded.
    static func entry(at path: String) -> Entry {
        var info = stat()
        if stat(path, &info) == 0 { return .present }
        let code = errno
        return code == ENOENT || code == ENOTDIR ? .absent : .unknown(code)
    }

    /// Whether a WAL may sit beside the store. A WAL whose existence cannot be determined counts as present, so the read
    /// goes through SQLite and reports why it failed.
    private static func walMayExist(_ path: String) -> Bool {
        entry(at: path + "-wal") != .absent
    }

    private static func readAnyMode(path: String, from: Date, to: Date, lockWait: UInt64) throws -> StoreSnapshot {
        do {
            return try read(SQLiteConnection(readingOnly: path, .sharedMemoryReadOnly, lockWait: lockWait), from: from, to: to)
        } catch let error as StoreReadFailure {
            throw error
        } catch StoreError.busy(let detail) {
            throw StoreReadFailure.locked(detail)
        } catch {
            // The read-only index is missing or cannot be used.
        }
        if walMayExist(path) {
            return try read(SQLiteConnection(readingOnly: path, .sharedMemoryWritable, lockWait: lockWait), from: from, to: to)
        }
        let snapshot: StoreSnapshot
        do {
            snapshot = try read(SQLiteConnection(readingOnly: path, .withoutWAL, lockWait: lockWait), from: from, to: to)
        } catch {
            // The app may have started writing during the read, leaving the main file alone out of date.
            guard walMayExist(path) else { throw error }
            return try read(SQLiteConnection(readingOnly: path, .sharedMemoryWritable, lockWait: lockWait), from: from, to: to)
        }
        guard walMayExist(path) else { return snapshot }
        return try read(SQLiteConnection(readingOnly: path, .sharedMemoryWritable, lockWait: lockWait), from: from, to: to)
    }

    static func read(_ connection: SQLiteConnection, from: Date, to: Date) throws -> StoreSnapshot {
        try connection.execute("BEGIN")
        defer { try? connection.execute("COMMIT") }
        let version = try ActivityStore.storedVersion(connection)
        let supported = ActivityStore.supportedSchemaVersion
        if version > supported { throw StoreReadFailure.newerSchema(found: version, supported: supported) }
        if version < supported { throw StoreReadFailure.olderSchema(found: version, supported: supported) }
        let blocks = to > from ? try connection.query(
            "SELECT \(ActivityStore.blockColumns()) FROM blocks WHERE start >= ? AND start < ? ORDER BY start",
            [.real(Block.bucketStart(containing: from).timeIntervalSince1970), .real(to.timeIntervalSince1970)]
        ).map { ActivityStore.block(from: $0) } : []
        let latest = try connection.query("SELECT MAX(end) FROM segments").first?.first?.double
        let classified = try connection.query("SELECT MAX(classified_at) FROM blocks WHERE label_state = 'classified'").first?.first?.double
        return StoreSnapshot(schemaVersion: version, blocks: blocks, latestSegmentEnd: latest.map(Date.init(timeIntervalSince1970:)),
                             lastClassified: classified.map(Date.init(timeIntervalSince1970:)))
    }
}
