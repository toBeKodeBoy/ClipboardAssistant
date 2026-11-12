import Foundation

/// Archive schema migration. Legacy rule/label tables remain inert for compatibility.
final class ArchiveSchema {
    private let database: SQLiteDatabase
    private let lock: NSLock
    init(database: SQLiteDatabase, lock: NSLock) { self.database = database; self.lock = lock }
    func migrate() throws {
        lock.lock(); defer { lock.unlock() }
        try database.execute("BEGIN IMMEDIATE")
        do {
        var version: Int64 = 0
        try database.query("PRAGMA user_version") { version = database.int64($0, 0) }
        guard version <= 4 else { throw ArchiveError.invalidFormat }
        try database.execute("CREATE TABLE IF NOT EXISTS item_labels (item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE, label TEXT NOT NULL);")
        try database.execute("CREATE TABLE IF NOT EXISTS item_files (item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE, metadata BLOB NOT NULL)")
        try database.execute("CREATE TABLE IF NOT EXISTS archive_jobs (id TEXT PRIMARY KEY, committed INTEGER NOT NULL)")
        try database.execute("CREATE TABLE IF NOT EXISTS archive_cleanup (item_id TEXT PRIMARY KEY)")
        try database.execute("CREATE TABLE IF NOT EXISTS history_revision (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL)")
        try database.execute("INSERT OR IGNORE INTO history_revision VALUES (1,0)")
        for table in ["items", "representations", "item_labels", "item_files"] {
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                try database.execute("CREATE TRIGGER IF NOT EXISTS revision_\(table)_\(operation) AFTER \(operation) ON \(table) BEGIN UPDATE history_revision SET revision=revision+1 WHERE id=1; END")
            }
        }
        try database.execute("PRAGMA user_version=4;")
        try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }
}
