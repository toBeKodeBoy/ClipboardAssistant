import Foundation
import SQLite3

/**
 * 对系统 sqlite3 的薄封装。
 *
 * 打开时启用外键和 WAL。sqlite3_step 失败必须抛错，调用方不能把失败当成空结果。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
final class SQLiteDatabase {
    /** 数据库连接。由本对象关闭。 */
    private var handle: OpaquePointer?

    /**
     * 打开或创建数据库。
     *
     * @param path 数据库文件路径
     * @throws StoreError.open 无法打开文件时抛出
     */
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

    /**
     * 关闭数据库连接。
     */
    deinit {
        sqlite3_close(handle)
    }

    /**
     * 执行不返回行的 SQL。
     *
     * @param sql 要执行的语句
     * @throws StoreError.sql 执行失败时抛出，消息来自 sqlite3
     */
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil), sql)
    }

    /**
     * 执行一条绑定参数的写入语句。
     *
     * sqlite3_step 不是 SQLITE_DONE 时抛错。
     *
     * @param sql 带占位符的语句
     * @param bind 向语句绑定参数
     * @throws StoreError.sql 准备或执行失败时抛出
     */
    func run(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)
        try check(sqlite3_step(statement), sql)
    }

    /**
     * 执行查询，并对每一行调用回调。
     *
     * sqlite3_step 返回 SQLITE_ROW 以外的错误码时抛错，不会把历史列表变成空的。
     *
     * @param sql 带占位符的查询
     * @param bind 向语句绑定参数
     * @param row 读取当前行。此时游标位于 SQLITE_ROW
     * @throws StoreError.sql 准备或读取失败时抛出
     */
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

    /**
     * 读取当前行的 64 位整数。
     *
     * @param statement 位于 SQLITE_ROW 的语句
     * @param index 从 0 开始的列序号
     * @return 列值
     */
    func int64(_ statement: OpaquePointer?, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    /**
     * 读取当前行的浮点数。
     *
     * @param statement 位于 SQLITE_ROW 的语句
     * @param index 从 0 开始的列序号
     * @return 列值
     */
    func double(_ statement: OpaquePointer?, _ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    /**
     * 读取当前行的文本。
     *
     * @param statement 位于 SQLITE_ROW 的语句
     * @param index 从 0 开始的列序号
     * @return 列文本，NULL 时返回空字符串
     */
    func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    /**
     * 读取可空文本。
     *
     * @param statement 位于 SQLITE_ROW 的语句
     * @param index 从 0 开始的列序号
     * @return 列文本；NULL 或空字符串时返回 nil
     */
    func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = text(statement, index)
        return value.isEmpty ? nil : value
    }

    /**
     * 准备语句。
     *
     * @param sql 要准备的 SQL
     * @return 准备好的语句，由调用方 finalize
     * @throws StoreError.sql 准备失败时抛出
     */
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), sql)
        return statement
    }

    /**
     * 把 sqlite3 结果码转成错误。
     *
     * SQLITE_OK、SQLITE_DONE 和 SQLITE_ROW 视为成功。
     *
     * @param code sqlite3 返回码
     * @param sql 失败时用于兜底的语句文本
     * @throws StoreError.sql code 表示失败时抛出
     */
    private func check(_ code: Int32, _ sql: String) throws {
        if code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW { return }
        let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? sql
        throw StoreError.sql(message)
    }
}

/**
 * 绑定可空文本参数。
 *
 * @param statement 已准备的语句
 * @param index 从 1 开始的参数序号
 * @param value 要绑定的文本，nil 绑成 NULL
 */
func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    if let value {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(statement, index)
    }
}
