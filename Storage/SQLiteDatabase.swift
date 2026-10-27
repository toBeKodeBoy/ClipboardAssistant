import Foundation
import SQLite3

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open"
            sqlite3_close(db)
            throw StoreError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil), sql)
    }

    func run(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)
        try check(sqlite3_step(statement), sql)
    }

    func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                row(statement)
                continue
            }
            if code == SQLITE_DONE { return }
            try check(code, sql)
        }
    }

    func int64(_ statement: OpaquePointer?, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func double(_ statement: OpaquePointer?, _ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = text(statement, index)
        return value.isEmpty ? nil : value
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), sql)
        return statement
    }

    private func check(_ code: Int32, _ sql: String) throws {
        if code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW { return }
        let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? sql
        throw StoreError.sql(message)
    }
}

func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    if let value {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(statement, index)
    }
}
