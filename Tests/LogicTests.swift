import Carbon
import XCTest
@testable import ClipboardAssistant

final class LogicTests: XCTestCase {
    func testTextNormalizationAndStableHash() {
        let left = ContentHash.text("alpha\r\nbeta")
        let right = ContentHash.text("alpha\nbeta")
        XCTAssertEqual(left, right)
        XCTAssertEqual(ContentHash.normalizeText("a\r\nb"), "a\nb")
        XCTAssertNotEqual(ContentHash.text("alpha"), ContentHash.text(" alpha"))
    }

    func testPrivacyGateSkipsPausedConcealedAndExcluded() {
        var decision = PrivacyDecision(
            isPaused: false,
            secureInputEnabled: false,
            recordDuringSecureInput: false,
            ignoreConcealed: true,
            hasConcealedMarker: false,
            sourceBundleID: "com.example.app",
            excludedBundleIDs: ["com.1password.1password"],
            isSelfWrite: false
        )
        XCTAssertTrue(PrivacyGate.allowsCapture(decision))
        decision.isPaused = true
        XCTAssertFalse(PrivacyGate.allowsCapture(decision))
        decision.isPaused = false
        decision.hasConcealedMarker = true
        XCTAssertFalse(PrivacyGate.allowsCapture(decision))
        decision.hasConcealedMarker = false
        decision.secureInputEnabled = true
        XCTAssertFalse(PrivacyGate.allowsCapture(decision))
        decision.recordDuringSecureInput = true
        XCTAssertTrue(PrivacyGate.allowsCapture(decision))
        decision.sourceBundleID = "com.1password.1password"
        XCTAssertFalse(PrivacyGate.allowsCapture(decision))
        decision.sourceBundleID = "com.example.app"
        decision.isSelfWrite = true
        XCTAssertFalse(PrivacyGate.allowsCapture(decision))
        decision.isSelfWrite = false
        decision.hasTransientMarker = true
        decision.ignoreConcealed = false
        XCTAssertFalse(PrivacyGate.allowsCapture(decision))
    }

    func testRetentionKeepsPinnedItems() throws {
        let now = Date()
        let pinned = sample(id: "pin", pinned: true, createdAt: now.addingTimeInterval(-10 * 86_400), lastUsedAt: now.addingTimeInterval(-9 * 86_400))
        let old = sample(id: "old", pinned: false, createdAt: now.addingTimeInterval(-40 * 86_400), lastUsedAt: now.addingTimeInterval(-40 * 86_400))
        let newest = sample(id: "new", pinned: false, createdAt: now, lastUsedAt: now)
        let middle = sample(id: "mid", pinned: false, createdAt: now.addingTimeInterval(-3600), lastUsedAt: now.addingTimeInterval(-3600))
        let policy = RetentionPolicy(maxCount: 2, maxAge: 30 * 86_400, maxImageBytes: 200)
        let doomed = Set(policy.expiredAndOverflowIDs(in: [pinned, old, newest, middle], now: now))
        XCTAssertTrue(doomed.contains("old"))
        XCTAssertFalse(doomed.contains("pin"))
        XCTAssertFalse(doomed.contains("new"))
    }

    func testImageCapRemovesOldestUnpinnedImage() {
        let now = Date()
        let pinned = sample(id: "pin", pinned: true, kind: .image, byteSize: 500, lastUsedAt: now.addingTimeInterval(-10))
        let older = sample(id: "old", pinned: false, kind: .image, byteSize: 150, lastUsedAt: now.addingTimeInterval(-20))
        let newer = sample(id: "new", pinned: false, kind: .image, byteSize: 80, lastUsedAt: now)
        let policy = RetentionPolicy(maxCount: nil, maxAge: nil, maxImageBytes: 200)
        XCTAssertEqual(policy.imageOverflowIDs(in: [pinned, older, newer]), ["old"])
    }

    func testSearchMatchesChineseAndFileName() {
        let item = sample(id: "1", plainText: "构建失败：权限校验错误\n需求评审.pdf")
        XCTAssertTrue(HistoryQuery.matches(item, query: "错误", filter: .all))
        XCTAssertTrue(HistoryQuery.matches(item, query: "需求评审", filter: .all))
        XCTAssertFalse(HistoryQuery.matches(item, query: "不存在", filter: .all))
        XCTAssertFalse(HistoryQuery.matches(item, query: "", filter: .image))
    }

    func testCaptureBuilderDedupesNormalizedText() {
        let first = CaptureBuilder.build(snapshot(["a\r\nb"]))
        let second = CaptureBuilder.build(snapshot(["a\nb"]))
        XCTAssertEqual(first?.contentHash, second?.contentHash)
        XCTAssertEqual(first?.kind, .text)
    }

    func testOversizeTextKeepsDistinctHashes() {
        let prefix = String(repeating: "a", count: 5_000)
        let first = CaptureBuilder.build(snapshot([prefix + "one"]), limits: CaptureLimits(maxTextBytes: 100, maxImageBytes: 100, previewBytes: 8))
        let second = CaptureBuilder.build(snapshot([prefix + "two"]), limits: CaptureLimits(maxTextBytes: 100, maxImageBytes: 100, previewBytes: 8))
        XCTAssertNotEqual(first?.contentHash, second?.contentHash)
        XCTAssertEqual(first?.oversize, true)
        XCTAssertEqual(first?.representations.isEmpty, true)
        XCTAssertEqual(first?.plainText.count, 8)
    }

    func testTruncatedPayloadUsesFullDigest() {
        let item = PasteboardItemData(
            values: [PasteboardUTI.plain: Data("preview".utf8)],
            fullDigests: [PasteboardUTI.plain: "digest-a"],
            fullByteCounts: [PasteboardUTI.plain: 2_000_000]
        )
        let other = PasteboardItemData(
            values: [PasteboardUTI.plain: Data("preview".utf8)],
            fullDigests: [PasteboardUTI.plain: "digest-b"],
            fullByteCounts: [PasteboardUTI.plain: 2_000_000]
        )
        let limits = CaptureLimits(maxTextBytes: 100, maxImageBytes: 100, previewBytes: 8)
        let first = CaptureBuilder.build(PasteboardSnapshot(items: [item]), limits: limits)
        let second = CaptureBuilder.build(PasteboardSnapshot(items: [other]), limits: limits)
        XCTAssertEqual(first?.contentHash, "digest-a")
        XCTAssertEqual(second?.contentHash, "digest-b")
        XCTAssertEqual(first?.byteSize, 2_000_000)
    }

    func testRichTextWithoutPlainUsesRichBytes() {
        let first = CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.rtf: Data("rich-a".utf8)])
        ]))
        let second = CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.rtf: Data("rich-b".utf8)])
        ]))
        XCTAssertEqual(first?.kind, .rich)
        XCTAssertNotEqual(first?.contentHash, second?.contentHash)
        XCTAssertNotEqual(first?.contentHash, ContentHash.text(""))
    }

    func testPlainCopyDoesNotSendKeystroke() {
        XCTAssertFalse(PasteMode.plainCopy.sendsKeystroke)
        XCTAssertTrue(PasteMode.plainCopy.writesPlainText)
        XCTAssertTrue(PasteMode.plainText.sendsKeystroke)
        XCTAssertFalse(PasteMode.copyOnly.sendsKeystroke)
        XCTAssertFalse(HotkeyCodec.isReserved(keyCode: UInt16(kVK_ANSI_V), flags: [.command, .shift]))
        XCTAssertTrue(HotkeyCodec.isReserved(keyCode: UInt16(kVK_ANSI_V), flags: [.command]))
        XCTAssertTrue(HotkeyCodec.isReserved(keyCode: UInt16(kVK_ANSI_C), flags: [.command]))
    }

    func testPlainPasteHashUsesPlainText() {
        let item = sample(id: "1", plainText: "hello")
        XCTAssertEqual(PasteboardWriter.plainHash(for: item), ContentHash.text("hello"))
    }

    func testHistoryCountsSeparatesPinnedAndKinds() {
        let items = [
            sample(id: "1", pinned: true, kind: .text),
            sample(id: "2", kind: .text),
            sample(id: "3", kind: .image),
            sample(id: "4", kind: .file),
            sample(id: "5", kind: .rich),
            sample(id: "6", kind: .mixed)
        ]
        let counts = HistoryCounts.tally(items)
        XCTAssertEqual(counts.total, 6)
        XCTAssertEqual(counts.pinned, 1)
        XCTAssertEqual(counts.unpinned, 5)
        XCTAssertEqual(counts.count(for: .text), 2)
        XCTAssertEqual(counts.count(for: .image), 1)
        XCTAssertEqual(counts.count(for: .file), 1)
        XCTAssertEqual(counts.count(for: .rich), 1)
        XCTAssertEqual(counts.count(for: .mixed), 1)
        XCTAssertEqual(counts.diagnosticCounts["pinned"], 1)
        XCTAssertEqual(counts.diagnosticCounts["unpinned"], 5)
        let limited = counts.panelSummary(maxCount: 500)
        XCTAssertTrue(limited.contains("500"))
        XCTAssertTrue(limited.contains("未置顶") || limited.contains("unpinned"))
        let unlimited = counts.panelSummary(maxCount: 0)
        XCTAssertTrue(unlimited.contains("不限制") || unlimited.contains("No limit"))
    }

    func testGroupingPlacesRecentUnpinnedInJustNow() {
        let item = sample(id: "1", lastUsedAt: Date())
        XCTAssertEqual(HistoryGrouping.section(for: item), .justNow)
        var pinned = item
        pinned.pinned = true
        XCTAssertEqual(HistoryGrouping.section(for: pinned), .pinned)
    }

    func testLogsDirectoryLivesInTheProject() throws {
        let directory = try AppPaths.logsDirectory()
        XCTAssertEqual(directory.lastPathComponent, "logs")
        XCTAssertTrue(directory.path.contains("clipboard-assistant"))
    }

    func testDailyLogWritesOneFilePerDayAndDropsOlderFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let log = DailyLog(directory: directory, calendar: calendar, retentionDays: 14)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("clipboard-2026-09-01.log").path, contents: Data("old\n".utf8))
        FileManager.default.createFile(atPath: directory.appendingPathComponent("clipboard-2026-10-20.log").path, contents: Data("kept\n".utf8))
        FileManager.default.createFile(atPath: directory.appendingPathComponent("notes.txt").path, contents: Data("keep\n".utf8))
        log.write(level: "info", category: "store", message: "launch", now: utcDate(year: 2026, month: 10, day: 27, hour: 13))
        log.write(level: "error", category: "store", message: "database open failed", now: utcDate(year: 2026, month: 10, day: 28, hour: 0))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["clipboard-2026-10-20.log", "clipboard-2026-10-27.log", "clipboard-2026-10-28.log", "notes.txt"])
        let today = try String(contentsOf: directory.appendingPathComponent("clipboard-2026-10-27.log"), encoding: .utf8)
        XCTAssertTrue(today.contains("2026-10-27 13:00:00.000 info store launch"))
        let next = try String(contentsOf: directory.appendingPathComponent("clipboard-2026-10-28.log"), encoding: .utf8)
        XCTAssertTrue(next.contains("error store database open failed"))
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func snapshot(_ lines: [String]) -> PasteboardSnapshot {
        let data = lines.joined(separator: "\n").data(using: .utf8) ?? Data()
        return PasteboardSnapshot(items: [PasteboardItemData(values: [PasteboardUTI.plain: data])])
    }

    private func sample(
        id: String,
        pinned: Bool = false,
        kind: ItemKind = .text,
        plainText: String = "text",
        byteSize: Int = 4,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            kind: kind,
            plainText: plainText,
            contentHash: id,
            sourceBundleID: "com.example",
            sourceName: "Example",
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            pinned: pinned,
            pinOrder: pinned ? 1 : nil,
            byteSize: byteSize,
            imageWidth: kind == .image ? 10 : nil,
            imageHeight: kind == .image ? 10 : nil,
            payloadOversize: false
        )
    }
}
