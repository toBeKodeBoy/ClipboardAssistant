import Foundation
import SQLite3

/// Shares HistoryStore's connection and lock in the app. Standalone initializer supports isolated storage tests.
final class SnippetStore {
    private let database: SQLiteDatabase
    private let lock: NSLock
    private struct VariableEnvelope: Codable {
        var schemaVersion = 1
        var fields: [SnippetVariable]
    }

    init(database: SQLiteDatabase, lock: NSLock) {
        self.database = database
        self.lock = lock
    }

    convenience init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.init(database: try SQLiteDatabase(path: directory.appendingPathComponent("history.db").path), lock: NSLock())
        try migrate()
    }

    /// Transactional additive migration. Unknown versions are never downgraded.
    func migrate() throws {
        try locked {
            try database.execute("BEGIN IMMEDIATE")
            do {
                var version: Int64 = 0
                try database.query("PRAGMA user_version") { version = database.int64($0, 0) }
                guard version <= 3 else { throw SnippetError.futureVersion }
                if version < 2 {
                    try database.execute("""
                        CREATE TABLE IF NOT EXISTS snippet_groups (
                            id TEXT PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE, created_at REAL NOT NULL
                        );
                        CREATE TABLE IF NOT EXISTS snippets (
                            id TEXT PRIMARY KEY, group_id TEXT REFERENCES snippet_groups(id) ON DELETE SET NULL,
                            title TEXT NOT NULL, body TEXT NOT NULL, keyword TEXT, keyword_key TEXT UNIQUE,
                            variables_json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL
                        );
                        CREATE INDEX IF NOT EXISTS idx_snippets_group_updated ON snippets(group_id, updated_at DESC);
                        PRAGMA user_version=2;
                        """)
                }
                // Validate before committing: incompatible pre-existing tables must fail the migration.
                try database.query("SELECT id, group_id, title, body, keyword, variables_json, created_at, updated_at FROM snippets LIMIT 0") { _ in }
                try database.execute("COMMIT")
            } catch {
                try? database.execute("ROLLBACK")
                throw error
            }
        }
    }

    func fetchAll() throws -> [Snippet] {
        try locked { try readAll() }
    }

    func fetchGroups() throws -> [SnippetGroup] {
        try locked {
            var result: [SnippetGroup] = []
            try database.query("SELECT id, name FROM snippet_groups ORDER BY created_at, id") {
                result.append(SnippetGroup(id: database.text($0, 0), name: database.text($0, 1)))
            }
            return result
        }
    }

    func save(_ draft: Snippet) throws -> Snippet {
        var value = try draft.validated()
        return try locked {
            try database.execute("BEGIN IMMEDIATE")
            do {
                let existing = try readAll().first { $0.id == value.id }
                if value.updatedAt != .distantPast {
                    guard existing?.updatedAt == value.updatedAt else { throw SnippetError.conflict }
                } else if existing != nil { throw SnippetError.conflict }
                value.updatedAt = max(Date(), value.updatedAt.addingTimeInterval(0.001))
                if let existing { value.createdAt = existing.createdAt }
                let json = try JSONEncoder().encode(VariableEnvelope(fields: value.variables))
                let sql = existing == nil
                    ? "INSERT INTO snippets(title,body,group_id,keyword,keyword_key,variables_json,created_at,updated_at,id) VALUES (?,?,?,?,?,?,?,?,?)"
                    : "UPDATE snippets SET title=?,body=?,group_id=?,keyword=?,keyword_key=?,variables_json=?,created_at=?,updated_at=? WHERE id=?"
                try database.run(sql) { statement in
                    bindText(statement, 1, value.title)
                    bindText(statement, 2, value.body)
                    bindText(statement, 3, value.groupID)
                    bindText(statement, 4, value.keyword.isEmpty ? nil : value.keyword)
                    bindText(statement, 5, value.keyword.isEmpty ? nil : value.keyword.lowercased())
                    bindText(statement, 6, String(decoding: json, as: UTF8.self))
                    sqlite3_bind_double(statement, 7, value.createdAt.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 8, value.updatedAt.timeIntervalSince1970)
                    bindText(statement, 9, value.id)
                }
                guard let persisted = try readAll().first(where: { $0.id == value.id }) else { throw SnippetError.storage }
                try database.execute("COMMIT")
                return persisted
            } catch {
                try? database.execute("ROLLBACK")
                if let known = error as? SnippetError { throw known }
                // Do not surface SQLite messages: unique-constraint errors may expose user content.
                throw SnippetError.conflict
            }
        }
    }

    @discardableResult
    func saveGroup(id: String? = nil, name: String) throws -> SnippetGroup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...30).contains(name.count), !name.contains("\0"),
              !["全部片段", "未分组", "all snippets", "ungrouped"].contains(name.lowercased()) else { throw SnippetError.invalidGroup }
        return try locked {
            let key = name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if let id {
                var exists = false
                try database.query("SELECT id FROM snippet_groups WHERE id=?", bind: { bindText($0, 1, id) }) { _ in exists = true }
                guard exists else { throw SnippetError.invalidGroup }
            }
            let result = SnippetGroup(id: id ?? UUID().uuidString, name: name)
            do {
                if id == nil {
                    try database.run("INSERT INTO snippet_groups(id,name,normalized_name,created_at) VALUES(?,?,?,?)") {
                        bindText($0, 1, result.id); bindText($0, 2, name); bindText($0, 3, key)
                        sqlite3_bind_double($0, 4, Date().timeIntervalSince1970)
                    }
                } else {
                    try database.run("UPDATE snippet_groups SET name=?,normalized_name=? WHERE id=?") {
                        bindText($0, 1, name); bindText($0, 2, key); bindText($0, 3, result.id)
                    }
                }
            } catch { throw SnippetError.invalidGroup }
            return result
        }
    }

    func delete(id: String) throws {
        try locked { try database.run("DELETE FROM snippets WHERE id=?") { bindText($0, 1, id) } }
    }

    func deleteGroup(id: String) throws {
        try locked { try database.run("DELETE FROM snippet_groups WHERE id=?") { bindText($0, 1, id) } }
    }

    private func readAll() throws -> [Snippet] {
        var result: [Snippet] = []
        var invalid = false
        try database.query("SELECT id,title,body,group_id,keyword,variables_json,created_at,updated_at FROM snippets ORDER BY updated_at DESC,id") { statement in
            let json = Data(database.text(statement, 5).utf8)
            guard let envelope = try? JSONDecoder().decode(VariableEnvelope.self, from: json), envelope.schemaVersion == 1 else {
                invalid = true; return
            }
            result.append(Snippet(id: database.text(statement, 0), title: database.text(statement, 1), body: database.text(statement, 2),
                groupID: database.optionalText(statement, 3), keyword: database.text(statement, 4), variables: envelope.fields,
                createdAt: Date(timeIntervalSince1970: database.double(statement, 6)), updatedAt: Date(timeIntervalSince1970: database.double(statement, 7))))
        }
        guard !invalid else { throw SnippetError.storage }
        return result
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
