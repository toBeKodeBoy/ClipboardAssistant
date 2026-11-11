import XCTest
@testable import ClipboardAssistant

final class HistoryArchiveTests: XCTestCase {
    func testRoundTripAndVersionRejection() throws {
        let archive = HistoryArchive(items: [])
        let data = try archive.encoded()
        XCTAssertEqual(try HistoryArchive.decode(data).items.count, 0)
        XCTAssertThrowsError(try HistoryArchive.decode(Data("{}".utf8)))
        let changed = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":99")
        XCTAssertThrowsError(try HistoryArchive.decode(Data(changed.utf8)))
    }
    func testTextExportHasExplicitPreviewMarker() {
        let record = ArchiveRecord(kind: .text, plainText: "中文\nline", sourceBundleID: nil, sourceName: "Demo",
            createdAt: Date(timeIntervalSince1970: 100), lastUsedAt: Date(timeIntervalSince1970: 100),
            pinned: false, label: nil, byteSize: 2000000, imageWidth: nil, imageHeight: nil,
            payloadOversize: true, representations: [])
        let text = HistoryArchive(items: [record]).plainTextExport()
        XCTAssertTrue(text.contains("中文\nline"))
        XCTAssertTrue(text.contains("Preview only"))
    }
}
