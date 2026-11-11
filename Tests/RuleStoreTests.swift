import XCTest
@testable import ClipboardAssistant

final class RuleStoreTests: XCTestCase {
    func testPersistenceAndValidation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try SQLiteDatabase(path: path.path)
        let store = RuleStore(database: database, lock: NSLock())
        try store.migrate()
        XCTAssertEqual(try store.load(), try CaptureRuleSet())
        let config = try CaptureRuleSet(tags: [AppTagRule(bundleID: "app", label: "work")], ignores: [TextIgnoreRule(name: "test", pattern: "example")])
        try store.save(config)
        let reopened = RuleStore(database: try SQLiteDatabase(path: path.path), lock: NSLock())
        XCTAssertEqual(try reopened.load(), config)
        try store.save(CaptureRuleSet())
        XCTAssertEqual(try reopened.load(), try CaptureRuleSet())
        try database.run("UPDATE capture_rules SET config = ? WHERE id=1") { bindText($0, 1, "{}") }
        XCTAssertThrowsError(try store.load())
    }
}

extension RuleStoreTests {
    func testUnknownVersionIsRejectedWithoutDowngrade() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("PRAGMA user_version=4")
        let store = RuleStore(database: database, lock: NSLock())
        XCTAssertThrowsError(try store.migrate())
        var version: Int64 = 0
        try database.query("PRAGMA user_version") { version = database.int64($0, 0) }
        XCTAssertEqual(version, 4)
    }
}
