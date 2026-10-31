import Foundation
import SQLite3

/**
 * 剪切板历史存储。
 *
 * 元数据在 SQLite，图片和原始负载在文件。删除先删数据库行，成功后再删文件。
 * 对外方法都加锁，sqlite3_step 失败时抛错。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
final class HistoryStore {
    /** 应用支持目录，数据库和负载都在这里。 */
    let directory: URL
    /** 历史元数据库。 */
    private let database: SQLiteDatabase
    /** 负载文件和缩略图。 */
    private let payloads: PayloadStore
    /** 保护数据库和文件的同一把锁。 */
    private let lock = NSLock()

    /**
     * 打开目录中的历史库，并在缺表时建表。
     *
     * @param directory 应用支持目录
     * @throws StoreError 数据库无法打开或建表失败时抛出
     */
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: directory.appendingPathComponent("history.db").path)
        payloads = try PayloadStore(root: directory)
        try migrate()
    }

    /**
     * 读取全部历史。
     *
     * 置顶在前，置顶内部按 pinOrder，其余按最近使用时间从新到旧。
     *
     * @return 全部条目
     * @throws StoreError.sql 查询失败时抛出，调用方不得把失败显示成空列表
     */
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

    /**
     * 插入新条目，或在哈希已存在时把原条目移到最新。
     *
     * 命中已有哈希时只更新使用时间、来源应用和来源名称。新条目在一个事务里写元数据和负载，失败则回滚并删掉已写出的文件。
     *
     * @param captured 采集结果
     * @param sourceBundleID 来源应用 bundle id
     * @param sourceName 来源应用显示名
     * @param now 本次复制时间
     * @return 插入或更新后的条目
     * @throws StoreError.sql 写入失败时抛出
     */
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

    /**
     * 读取一条历史的负载索引。
     *
     * @param id 条目标识
     * @return 负载索引，不含文件字节
     * @throws StoreError.sql 查询失败时抛出
     */
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

    /**
     * 按相对路径读取负载字节。
     *
     * @param relativePath 相对应用支持目录的路径
     * @return 文件内容；读取失败时返回 nil
     */
    func data(relativePath: String) -> Data? {
        payloads.read(relativePath: relativePath)
    }

    /**
     * 返回已存在的缩略图地址。
     *
     * @param id 条目标识
     * @return 缩略图文件 URL；还没生成时返回 nil
     */
    func thumbnailURL(for id: String) -> URL? {
        let url = payloads.fileURL(relativePath: "thumbs/\(id).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /**
     * 读出可重新入库的负载。
     *
     * 供删除撤销使用，会把文件内容读进内存。
     *
     * @param id 条目标识
     * @return 可交给 insertOrTouch 的负载
     * @throws StoreError.sql 查询索引失败时抛出
     */
    func loadRepresentations(for id: String) throws -> [CapturedRepresentation] {
        try representations(for: id).map { stored in
            CapturedRepresentation(
                uti: stored.uti,
                data: stored.relativePath.flatMap { data(relativePath: $0) },
                inlineValue: stored.inlineValue
            )
        }
    }

    /**
     * 删除一条历史。
     *
     * 先删数据库行，成功后再删负载文件。数据库失败时文件仍保留。
     *
     * @param id 条目标识
     * @throws StoreError.sql 删行失败时抛出
     */
    func delete(id: String) throws {
        try locked {
            try database.run("DELETE FROM items WHERE id = ?") { bindText($0, 1, id) }
            payloads.removeItem(id: id)
        }
    }

    /**
     * 清空全部历史，包括置顶条目。
     *
     * 先删行并删除负载，再执行 VACUUM。
     *
     * @throws StoreError.sql 清空或 VACUUM 失败时抛出
     */
    func clearAll() throws {
        try locked {
            try database.execute("DELETE FROM items")
            payloads.removeAllPayloads()
            try database.execute("VACUUM")
        }
    }

    /**
     * 设置或取消置顶。
     *
     * 新置顶使用当前最大 pinOrder 加一，取消时清空顺序。
     *
     * @param id 条目标识
     * @param pinned true 为置顶，false 为取消
     * @throws StoreError.sql 更新失败时抛出
     */
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

    /**
     * 按保留策略删除过期、超条数和超图片容量的条目。
     *
     * 置顶不参与这三项淘汰。
     *
     * @param policy 当前保留策略
     * @param now 判定时刻
     * @throws StoreError.sql 读取或删除失败时抛出
     */
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

    /**
     * 统计历史条数。
     *
     * @return 数据库中的条目数，含置顶
     * @throws StoreError.sql 查询失败时抛出
     */
    func count() throws -> Int {
        try locked {
            var count = 0
            try database.query("SELECT COUNT(*) FROM items") { statement in
                count = Int(database.int64(statement, 0))
            }
            return count
        }
    }

    /**
     * 创建历史表、负载表和索引。
     *
     * 已存在时不改表结构。user_version 固定为 1。
     *
     * @throws StoreError.sql 建表失败时抛出
     */
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

    /**
     * 按内容哈希查找已有条目。
     *
     * @param hash 内容哈希
     * @return 已有条目；没有时返回 nil
     * @throws StoreError.sql 查询失败时抛出
     */
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

    /**
     * 把当前查询行读成历史条目。
     *
     * @param statement 位于 SQLITE_ROW 的语句，列顺序与列表查询一致
     * @return 历史条目
     */
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

    /**
     * 把二进制负载写入文件。
     *
     * @param representation 采集到的一种负载
     * @param itemID 条目标识
     * @return 相对路径；只有 inlineValue、没有 data 时返回 nil
     * @throws 写文件失败时抛出
     */
    private func store(_ representation: CapturedRepresentation, itemID: String) throws -> String? {
        if let data = representation.data {
            return try payloads.write(itemID: itemID, uti: representation.uti, data: data)
        }
        return nil
    }

    /**
     * 计算下一次置顶顺序。
     *
     * @return 当前最大 pinOrder 加一；还没有置顶时为 1
     * @throws StoreError.sql 查询失败时抛出
     */
    private func nextPinOrder() throws -> Int64 {
        var order: Int64 = 0
        try database.query("SELECT COALESCE(MAX(pin_order), 0) FROM items") { statement in
            order = database.int64(statement, 0) + 1
        }
        return order
    }

    /**
     * 在存储锁内执行操作。
     *
     * @param body 需要独占数据库和负载文件的操作
     * @return body 的返回值
     * @throws body 抛出的错误
     */
    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static let imageUTIs: Set<String> = [PasteboardUTI.png, PasteboardUTI.tiff, PasteboardUTI.jpeg]
}

/**
 * 绑定可空整数参数。
 *
 * @param statement 已准备的语句
 * @param index 从 1 开始的参数序号
 * @param value 要绑定的整数，nil 绑成 NULL
 */
private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
    if let value {
        sqlite3_bind_int64(statement, index, Int64(value))
    } else {
        sqlite3_bind_null(statement, index)
    }
}
