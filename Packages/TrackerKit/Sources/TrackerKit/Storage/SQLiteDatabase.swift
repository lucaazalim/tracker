import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

/// A minimal, synchronous SQLite wrapper. Not thread-safe on its own; owned by an actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Tells SQLite to copy bound buffers. The C macro `SQLITE_TRANSIENT` isn't imported into Swift.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    /// Opens (creating if needed) the database at `path`. Pass `":memory:"` for an in-memory database.
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close(handle)
            throw SQLiteError(code: status, message: message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error(status) }
    }

    /// Runs a multi-statement script (no bindings), e.g. schema migrations.
    func executeScript(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw error(status) }
    }

    func query<Row>(_ sql: String, _ bindings: [SQLiteValue] = [], row: (Statement) throws -> Row) throws -> [Row] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error(status) }
            rows.append(try row(Statement(pointer: statement)))
        }
        return rows
    }

    func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        try query(sql, bindings) { $0.int(0) }.first ?? 0
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK else { throw error(status) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .int(let int): sqlite3_bind_int64(statement, index, int)
            case .double(let double): sqlite3_bind_double(statement, index, double)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .blob(let data):
                data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error(result)
            }
        }
        return statement
    }

    private func error(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: String(cString: sqlite3_errmsg(handle)))
    }

    struct Statement {
        let pointer: OpaquePointer?

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(pointer, column)) }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(pointer, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(pointer, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(pointer, column) == SQLITE_NULL }

        func text(_ column: Int32) -> String? {
            guard let cString = sqlite3_column_text(pointer, column) else { return nil }
            return String(cString: cString)
        }

        func blob(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(pointer, column))
            guard count > 0, let bytes = sqlite3_column_blob(pointer, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }
}
