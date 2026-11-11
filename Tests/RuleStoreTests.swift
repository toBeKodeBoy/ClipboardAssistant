import XCTest
@testable import ClipboardAssistant

final class RuleStoreTests: XCTestCase {
    func testPersistenceAndValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(directory: root)
        let config = try CaptureRuleSet(tags: [AppTagRule(bundleID: "app", label: "work")], ignores: [])
        try store.rules.save(config)
        XCTAssertEqual(try HistoryStore(directory: root).rules.load(), config)
        try store.clearAll()
        XCTAssertEqual(try store.rules.load(), config)
    }
}
