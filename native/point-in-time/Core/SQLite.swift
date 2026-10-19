import Foundation
import SQLite3

/// Errors from the local store. Messages never include captured content.
public enum StoreError: Error, Equatable, CustomStringConvertible {
    case open(String)
    case sqlite(String)
    case newerSchema(found: Int, supported: Int)
    case filesystem(String)

    public var description: String {
        switch self {
        case .open(let message): "Could not open the activity store: \(message)"
        case .sqlite(let message): "Activity store error: \(message)"
        case .newerSchema(let found, let supported): "The activity store uses schema \(found); this version supports up to \(supported)."
        case .filesystem(let message): "Activity store folder error: \(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal SQLite connection. Callers serialize access; `ActivityStore` holds a lock around every use.
///
/// Capture writes from the main actor, so a statement that another connection's lock blocks waits about
/// `busyWaitNanoseconds` and then fails with SQLITE_BUSY; the WAL checkpoint does not wait at all. The failed write
/// stays queued in `PendingWrites` and is retried on the next sample, so contention delays a write instead of the app.
final class SQLiteConnection {
    /// How long one lock request waits for another connection, 100 ms. pointInTime is the only writer, so this only covers
    /// another process's brief write; a longer hold is a failure that the write queue retries.
    static let busyWaitNanoseconds: UInt64 = 100_000_000

    private var handle: OpaquePointer?
    private var busyWait = SQLiteConnection.busyWaitNanoseconds
    private var busySince: UInt64 = 0

    /// Opens `path` read-write, creating it if needed.
    convenience init(path: String) throws {
        try self.init(filename: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    }

    /// How a read-only connection treats the WAL index (-shm) and the WAL.
    enum ReadOnlyMode: String {
        /// Opens the -shm read-only as well, so reading changes no file at all; fails when the -shm file is missing.
        case sharedMemoryReadOnly = "mode=ro&readonly_shm=1"
        /// Needs a writable -shm to read the WAL and may create one.
        case sharedMemoryWritable = "mode=ro"
        /// Reads only the main file and creates nothing; correct only when there is no WAL file to read.
        case withoutWAL = "mode=ro&immutable=1"
    }

    /// Opens `path` only to read it. Closing a read-only connection never checkpoints or removes a WAL.
    convenience init(readingOnly path: String, _ mode: ReadOnlyMode) throws {
        let uri = URL(fileURLWithPath: path).absoluteString + "?" + mode.rawValue
        try self.init(filename: uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }

    private init(filename: String, flags: Int32) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(filename, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            if let db { sqlite3_close(db) }
            throw StoreError.open(message)
        }
        handle = db
        // The connection closes in deinit, so it outlives every call of the handler.
        sqlite3_busy_handler(db, { context, attempt in
            guard let context else { return 0 }
            return Unmanaged<SQLiteConnection>.fromOpaque(context).takeUnretainedValue().waitsWhileBusy(attempt) ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// SQLite's own busy timeout adds up the sleeps it asks for, which macOS can stretch several times over, so the wait
    /// is measured on the clock instead.
    private func waitsWhileBusy(_ attempt: Int32) -> Bool {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if attempt == 0 { busySince = now }
        guard now - busySince < busyWait else { return false }
        usleep(2_000)
        return true
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    /// Copies the WAL into the database and truncates it, and throws unless that completed. SQLite reports a checkpoint
    /// that another connection's read blocked in the pragma's result row (busy, log frames, checkpointed frames), not as
    /// an error, so the row is read and checked. A truncating checkpoint waits on the busy handler until every reader
    /// ends, which can be any length of time, so it runs without one and reports a blocked checkpoint at once.
    func checkpointTruncatingWAL() throws {
        busyWait = 0
        defer { busyWait = Self.busyWaitNanoseconds }
        let row = try query("PRAGMA wal_checkpoint(TRUNCATE)").first
        guard let row, row.count == 3, row[0].int == 0, row[1].int == row[2].int else {
            throw StoreError.sqlite("The WAL checkpoint could not complete because another connection is reading")
        }
    }

    /// Runs one statement with positional bindings and returns every row as column values.
    @discardableResult
    func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let status: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .integer(let integer): sqlite3_bind_int64(statement, position, integer)
            case .real(let real): sqlite3_bind_double(statement, position, real)
            // An explicit byte count keeps text after an embedded NUL.
            case .text(let text): text.utf8CString.withUnsafeBufferPointer { buffer in
                sqlite3_bind_text(statement, position, buffer.baseAddress, Int32(buffer.count - 1), SQLITE_TRANSIENT)
            }
            }
            guard status == SQLITE_OK else { throw error() }
        }
        var rows: [[SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error() }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(Self.text(statement, column))
                default: .null
                }
            })
        }
        return rows
    }

    /// The column's text by its byte length, so an embedded NUL does not cut it short.
    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func error() -> StoreError {
        .sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}

enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    init(_ text: String?) { self = text.map { .text($0) } ?? .null }

    var double: Double? {
        switch self {
        case .real(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    var int: Int? {
        switch self {
        case .integer(let value): Int(value)
        case .real(let value): Int(value)
        default: nil
        }
    }

    var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}
