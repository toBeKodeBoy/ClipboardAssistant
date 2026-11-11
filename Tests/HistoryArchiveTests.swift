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

extension HistoryArchiveTests {
    func testValidRepresentationsAndInvalidRecords() throws {
        let rep = ArchiveRepresentation(uti: "public.utf8-plain-text", data: Data("hello".utf8), inlineValue: nil)
        let record = ArchiveRecord(kind: .text, plainText: "hello", sourceBundleID: "demo", sourceName: "Demo", createdAt: Date(timeIntervalSince1970: 100), lastUsedAt: Date(timeIntervalSince1970: 100), pinned: true, label: "work", byteSize: 5, imageWidth: nil, imageHeight: nil, payloadOversize: false, representations: [rep])
        let archive = HistoryArchive(items: [record])
        XCTAssertEqual(try HistoryArchive.decode(archive.encoded()).items, archive.items)
        XCTAssertTrue(archive.plainTextExport().contains("hello"))
        var changed = record; changed.representations = []
        XCTAssertThrowsError(try HistoryArchive(items: [changed]).validate())
        changed = record; changed.byteSize = -1
        XCTAssertThrowsError(try HistoryArchive(items: [changed]).validate())
        changed = record; changed.payloadOversize = true
        XCTAssertThrowsError(try HistoryArchive(items: [changed]).validate())
        changed = record; changed.representations = [rep, rep]
        XCTAssertThrowsError(try HistoryArchive(items: [changed]).validate())
        changed = record; changed.representations[0].uti = "unsupported"
        XCTAssertThrowsError(try HistoryArchive(items: [changed]).validate())
        changed = record; changed.representations[0].data = Data(repeating: 0, count: 1048577)
        XCTAssertThrowsError(try HistoryArchive(items: [changed]).validate())
        changed = record; changed.representations[0].data = nil; changed.representations[0].inlineValue = "file:///tmp/demo"
        try HistoryArchive(items: [changed]).validate()
        var many = HistoryArchive(items: Array(repeating: record, count: 10001))
        XCTAssertThrowsError(try many.validate())
        many.items = []; many.format = "other"
        XCTAssertThrowsError(try many.validate())
        XCTAssertThrowsError(try HistoryArchive.decode(Data(repeating: 0, count: HistoryArchive.maxBytes + 1)))
    }
}
extension RulesTests {
    func testIdentityAndEmptyConfiguration() throws {
        let rule = try AppTagRule(bundleID: "app", label: "label")
        XCTAssertEqual(rule.id, "app")
        XCTAssertFalse(try TextIgnoreRule(name: "test", pattern: "a").id.isEmpty)
        XCTAssertNil(try CaptureRuleSet().tag(for: nil))
    }
}

extension HistoryArchiveTests {
    func testArchiveAggregateAndEncodedSizeLimits() throws {
        let image = ArchiveRepresentation(uti: "public.png", data: Data(repeating: 0, count: 10485760), inlineValue: nil)
        let record = ArchiveRecord(kind: .image, plainText: "", sourceBundleID: nil, sourceName: "Demo", createdAt: Date(timeIntervalSince1970: 100), lastUsedAt: Date(timeIntervalSince1970: 100), pinned: false, label: nil, byteSize: 10485760, imageWidth: 100, imageHeight: 100, payloadOversize: false, representations: [image])
        XCTAssertThrowsError(try HistoryArchive(items: Array(repeating: record, count: 7)).validate())
        XCTAssertThrowsError(try HistoryArchive(items: Array(repeating: record, count: 5)).encoded())
    }
}
