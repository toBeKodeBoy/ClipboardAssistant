import Foundation
import SQLite3

final class HistoryStore {
    let directory: URL
    private let database: SQLiteDatabase
    private let payloads: PayloadStore
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: directory.appendingPathComponent("history.db").path)
        payloads = try PayloadStore(root: directory)
        try migrate()
    }

    func fetchAll() throws -> [ClipboardItem] {
        try locked {
            var items: [ClipboardItem] = []
            try database.query("""
                SELECT id, kind, plain_text, content_hash, source_bundle_id, source_name,
                       created_at, last_used_at, pinned, pin_order, byte_size,
                       image_width, image_height, payload_oversize
                FROM items
                ORDER BY pinned DESC, COALESCE(pin_order, 1000000) ASC, last_used_at DESC
                """) { statement in
                items.append(readItem(statement))
            }
            return items
        }
    }

    func insertOrTouch(_ captured: CapturedClipboard, sourceBundleID: String?, sourceName: String, now: Date = Date()) throws -> ClipboardItem {
        try locked {
            if let existing = try item(hash: captured.contentHash) {
                try database.run("""
                    UPDATE items SET last_used_at = ?, source_bundle_id = ?, source_name = ? WHERE id = ?
                    """) { statement in
                    sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                    bindText(statement, 2, sourceBundleID)
                    bindText(statement, 3, sourceName)
                    bindText(statement, 4, existing.id)
                }
                var updated = existing
                updated.lastUsedAt = now
                updated.sourceBundleID = sourceBundleID
                updated.sourceName = sourceName
                return updated
            }

            let id = UUID().uuidString
            try database.execute("BEGIN")
            do {
                try database.run("""
                    INSERT INTO items (
                        id, kind, plain_text, content_hash, source_bundle_id, source_name,
                        created_at, last_used_at, pinned, pin_order, byte_size,
                        image_width, image_height, payload_oversize
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?, ?)
                    """) { statement in
                    bindText(statement, 1, id)
                    bindText(statement, 2, captured.kind.rawValue)
                    bindText(statement, 3, captured.plainText)
                    bindText(statement, 4, captured.contentHash)
                    bindText(statement, 5, sourceBundleID)
                    bindText(statement, 6, sourceName)
                    sqlite3_bind_double(statement, 7, now.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 8, now.timeIntervalSince1970)
                    sqlite3_bind_int64(statement, 9, Int64(captured.byteSize))
                    bindOptionalInt(statement, 10, captured.imageWidth)
                    bindOptionalInt(statement, 11, captured.imageHeight)
                    sqlite3_bind_int(statement, 12, captured.oversize ? 1 : 0)
                }
                if !captured.oversize {
                    for representation in captured.representations {
                        let relative = try store(representation, itemID: id)
                        try database.run("""
                            INSERT INTO representations (item_id, uti, storage, relative_path, inline_value)
                            VALUES (?, ?, ?, ?, ?)
                            """) { statement in
                            bindText(statement, 1, id)
                            bindText(statement, 2, representation.uti)
                            bindText(statement, 3, relative == nil ? "inline" : "file")
                            bindText(statement, 4, relative)
                            bindText(statement, 5, representation.inlineValue)
                        }
                    }
                    if let image = captured.representations.first(where: { Self.imageUTIs.contains($0.uti) })?.data {
                        _ = payloads.writeThumbnail(itemID: id, imageData: image)
                    }
                }
                try database.execute("COMMIT")
            } catch {
                try? database.execute("ROLLBACK")
                payloads.removeItem(id: id)
                throw error
            }
            return ClipboardItem(
                id: id,
                kind: captured.kind,
                plainText: captured.plainText,
                contentHash: captured.contentHash,
                sourceBundleID: sourceBundleID,
                sourceName: sourceName,
                createdAt: now,
                lastUsedAt: now,
                pinned: false,
                pinOrder: nil,
                byteSize: captured.byteSize,
                imageWidth: captured.imageWidth,
                imageHeight: captured.imageHeight,
                payloadOversize: captured.oversize
            )
        }
    }

    func representations(for id: String) throws -> [StoredRepresentation] {
        try locked {
            var rows: [StoredRepresentation] = []
            try database.query("SELECT uti, storage, relative_path, inline_value FROM representations WHERE item_id = ?") { statement in
                bindText(statement, 1, id)
            } row: { statement in
                rows.append(StoredRepresentation(
                    uti: database.text(statement, 0),
                    storage: database.text(statement, 1),
                    relativePath: database.optionalText(statement, 2),
                    inlineValue: database.optionalText(statement, 3)
                ))
            }
            return rows
        }
    }

    func data(relativePath: String) -> Data? {
        payloads.read(relativePath: relativePath)
    }

    func thumbnailURL(for id: String) -> URL? {
        let url = payloads.fileURL(relativePath: "thumbs/\(id).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func loadRepresentations(for id: String) throws -> [CapturedRepresentation] {
        try representations(for: id).map { stored in
            CapturedRepresentation(
                uti: stored.uti,
                data: stored.relativePath.flatMap { data(relativePath: $0) },
                inlineValue: stored.inlineValue
            )
        }
    }

    func delete(id: String) throws {
        try locked {
            try database.run("DELETE FROM items WHERE id = ?") { bindText($0, 1, id) }
            payloads.removeItem(id: id)
        }
    }

    func clearAll() throws {
        try locked {
            try database.execute("DELETE FROM items")
            payloads.removeAllPayloads()
            try database.execute("VACUUM")
        }
    }

    func setPinned(id: String, pinned: Bool) throws {
        try locked {
            let order: Int64? = pinned ? try nextPinOrder() : nil
            try database.run("UPDATE items SET pinned = ?, pin_order = ? WHERE id = ?") { statement in
                sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
                if let order {
                    sqlite3_bind_int64(statement, 2, order)
                } else {
                    sqlite3_bind_null(statement, 2)
                }
                bindText(statement, 3, id)
            }
        }
    }

    func applyRetention(_ policy: RetentionPolicy, now: Date = Date()) throws {
        let items = try fetchAll()
        var doomed = Set(policy.expiredAndOverflowIDs(in: items, now: now))
        let remaining = items.filter { !doomed.contains($0.id) }
        for id in policy.imageOverflowIDs(in: remaining) {
            doomed.insert(id)
        }
        for id in doomed {
            try delete(id: id)
        }
    }

    func count() throws -> Int {
        try locked {
            var count = 0
            try database.query("SELECT COUNT(*) FROM items") { statement in
                count = Int(database.int64(statement, 0))
            }
            return count
        }
    }

    private func migrate() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                plain_text TEXT,
                content_hash TEXT NOT NULL,
                source_bundle_id TEXT,
                source_name TEXT,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                pin_order INTEGER,
                byte_size INTEGER NOT NULL,
                image_width INTEGER,
                image_height INTEGER,
                payload_oversize INTEGER NOT NULL DEFAULT 0
            );
            """)
        try database.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_items_hash ON items(content_hash);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_items_list ON items(pinned DESC, last_used_at DESC);")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS representations (
                item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                uti TEXT NOT NULL,
                storage TEXT NOT NULL,
                relative_path TEXT,
                inline_value TEXT,
                PRIMARY KEY (item_id, uti)
            );
            """)
        try database.execute("PRAGMA user_version = 1;")
    }

    private func item(hash: String) throws -> ClipboardItem? {
        var found: ClipboardItem?
        try database.query("""
            SELECT id, kind, plain_text, content_hash, source_bundle_id, source_name,
                   created_at, last_used_at, pinned, pin_order, byte_size,
                   image_width, image_height, payload_oversize
            FROM items WHERE content_hash = ? LIMIT 1
            """) { bindText($0, 1, hash) } row: { statement in
            found = readItem(statement)
        }
        return found
    }

    private func readItem(_ statement: OpaquePointer?) -> ClipboardItem {
        let pinOrder = sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : Int(database.int64(statement, 9))
        let width = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : Int(database.int64(statement, 11))
        let height = sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : Int(database.int64(statement, 12))
        return ClipboardItem(
            id: database.text(statement, 0),
            kind: ItemKind(rawValue: database.text(statement, 1)) ?? .text,
            plainText: database.text(statement, 2),
            contentHash: database.text(statement, 3),
            sourceBundleID: database.optionalText(statement, 4),
            sourceName: database.text(statement, 5),
            createdAt: Date(timeIntervalSince1970: database.double(statement, 6)),
            lastUsedAt: Date(timeIntervalSince1970: database.double(statement, 7)),
            pinned: database.int64(statement, 8) != 0,
            pinOrder: pinOrder,
            byteSize: Int(database.int64(statement, 10)),
            imageWidth: width,
            imageHeight: height,
            payloadOversize: database.int64(statement, 13) != 0
        )
    }

    private func store(_ representation: CapturedRepresentation, itemID: String) throws -> String? {
        if let data = representation.data {
            return try payloads.write(itemID: itemID, uti: representation.uti, data: data)
        }
        return nil
    }

    private func nextPinOrder() throws -> Int64 {
        var order: Int64 = 0
        try database.query("SELECT COALESCE(MAX(pin_order), 0) FROM items") { statement in
            order = database.int64(statement, 0) + 1
        }
        return order
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static let imageUTIs: Set<String> = [PasteboardUTI.png, PasteboardUTI.tiff, PasteboardUTI.jpeg]
}

private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
    if let value {
        sqlite3_bind_int64(statement, index, Int64(value))
    } else {
        sqlite3_bind_null(statement, index)
    }
}
