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
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var db: OpaquePointer?
        let status = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            if let db { sqlite3_close(db) }
            throw StoreError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
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
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
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
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
                default: .null
                }
            })
        }
        return rows
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
