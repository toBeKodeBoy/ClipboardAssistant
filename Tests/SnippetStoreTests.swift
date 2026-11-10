import XCTest
@testable import ClipboardAssistant

final class SnippetStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPersistenceUniquenessAndGroupDeletion() throws {
        let url = try directory()
        let store = try SnippetStore(directory: url)
        let group = try store.saveGroup(name: "工作")
        let snippet = try store.save(Snippet(title: "回复", body: "Hi {{name}}", groupID: group.id, keyword: ";reply"))
        XCTAssertThrowsError(try store.save(Snippet(title: "冲突", body: "x", keyword: ";REPLY")))
        XCTAssertThrowsError(try store.saveGroup(name: " 工作 "))
        let reopened = try SnippetStore(directory: url)
        XCTAssertEqual(try reopened.fetchAll(), [snippet])
        try store.deleteGroup(id: group.id)
        XCTAssertNil(try reopened.fetchAll().first?.groupID)
        XCTAssertEqual(try reopened.fetchAll().first?.body, "Hi {{name}}")
        try store.delete(id: snippet.id)
        XCTAssertTrue(try reopened.fetchAll().isEmpty)
    }

    func testStaleUpdatesAndMissingGroupsFailWithoutDataLoss() throws {
        let store = try SnippetStore(directory: directory())
        let original = try store.save(Snippet(title: "original", body: "safe"))
        var changed = original
        changed.title = "new"
        let updated = try store.save(changed)
        XCTAssertGreaterThan(updated.updatedAt, original.updatedAt)
        XCTAssertThrowsError(try store.save(original))
        XCTAssertEqual(try store.fetchAll().first?.title, "new")
        XCTAssertThrowsError(try store.save(Snippet(title: "x", body: "x", groupID: "missing")))
        try store.delete(id: original.id)
        XCTAssertThrowsError(try store.save(updated))
    }

    func testMigrationPreservesVersionOneHistoryAndRejectsFutureVersions() throws {
        let url = try directory()
        let db = try SQLiteDatabase(path: url.appendingPathComponent("history.db").path)
        try db.execute("CREATE TABLE items(id TEXT PRIMARY KEY, plain_text TEXT); INSERT INTO items VALUES ('keep', 'history'); PRAGMA user_version=1")
        _ = try SnippetStore(directory: url)
        var count: Int64 = 0
        try db.query("SELECT COUNT(*) FROM items WHERE id='keep'") { count = db.int64($0, 0) }
        XCTAssertEqual(count, 1)
        try db.query("PRAGMA user_version") { count = db.int64($0, 0) }
        XCTAssertEqual(count, 2)
        _ = try SnippetStore(directory: url)
        try db.execute("PRAGMA user_version=99")
        XCTAssertThrowsError(try SnippetStore(directory: url))
        try db.query("PRAGMA user_version") { count = db.int64($0, 0) }
        XCTAssertEqual(count, 99)
    }

    func testMigrationFailureRollsBackAndCanRetry() throws {
        let url = try directory()
        let db = try SQLiteDatabase(path: url.appendingPathComponent("history.db").path)
        try db.execute("CREATE TABLE snippets(invalid TEXT); PRAGMA user_version=1")
        XCTAssertThrowsError(try SnippetStore(directory: url))
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = db.int64($0, 0) }
        XCTAssertEqual(version, 1)
        try db.execute("DROP TABLE snippets")
        _ = try SnippetStore(directory: url)
    }
}
