import Foundation

/// Shares the history database lock; rule changes never delete historical labels.
final class RuleStore {
    private let database: SQLiteDatabase
    private let lock: NSLock
    init(database: SQLiteDatabase, lock: NSLock) { self.database = database; self.lock = lock }
    func migrate() throws {
        lock.lock(); defer { lock.unlock() }
        try database.execute("BEGIN IMMEDIATE")
        do {
        var version: Int64 = 0
        try database.query("PRAGMA user_version") { version = database.int64($0, 0) }
        guard version <= 3 else { throw ArchiveError.invalidFormat }
        try database.execute("CREATE TABLE IF NOT EXISTS capture_rules (id INTEGER PRIMARY KEY CHECK(id = 1), config TEXT NOT NULL);")
        try database.execute("CREATE TABLE IF NOT EXISTS item_labels (item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE, label TEXT NOT NULL);")
        try database.execute("PRAGMA user_version=3;")
        try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }
    func load() throws -> CaptureRuleSet {
        lock.lock(); defer { lock.unlock() }
        var stored: Data?
        try database.query("SELECT config FROM capture_rules WHERE id=1") { row in
            stored = Data(database.text(row, 0).utf8)
        }
        guard let stored else { return try CaptureRuleSet() }
        return try JSONDecoder().decode(CaptureRuleSet.self, from: stored).validated()
    }
    func save(_ config: CaptureRuleSet) throws {
        let validated = try config.validated()
        let json = String(decoding: try JSONEncoder().encode(validated), as: UTF8.self)
        lock.lock(); defer { lock.unlock() }
        try database.run("INSERT INTO capture_rules (id,config) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET config=excluded.config") { bindText($0, 1, json) }
    }
}
