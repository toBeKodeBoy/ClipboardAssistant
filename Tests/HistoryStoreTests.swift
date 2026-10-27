import XCTest
@testable import ClipboardAssistant

final class HistoryStoreTests: XCTestCase {
    func testInsertTouchDeleteAndClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try HistoryStore(directory: directory)
        let captured = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.plain: Data("hello".utf8)])
        ])))
        let inserted = try store.insertOrTouch(captured, sourceBundleID: "com.apple.Terminal", sourceName: "Terminal", now: Date(timeIntervalSince1970: 10))
        let touched = try store.insertOrTouch(captured, sourceBundleID: "com.apple.Terminal", sourceName: "Terminal", now: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(inserted.id, touched.id)
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.fetchAll().first?.lastUsedAt, Date(timeIntervalSince1970: 20))

        try store.setPinned(id: inserted.id, pinned: true)
        XCTAssertEqual(try store.fetchAll().first?.pinned, true)

        let plain = PasteboardWriter.plainHash(for: try XCTUnwrap(store.fetchAll().first))
        XCTAssertFalse(plain.isEmpty)

        try store.delete(id: inserted.id)
        XCTAssertEqual(try store.count(), 0)
        let again = try store.insertOrTouch(captured, sourceBundleID: nil, sourceName: "Finder")
        try store.clearAll()
        XCTAssertEqual(try store.count(), 0)
        XCTAssertFalse(again.id.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }
}
