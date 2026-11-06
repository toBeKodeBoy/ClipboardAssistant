import AppKit
import ApplicationServices
import Carbon
import SQLite3
import SwiftUI
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

    func testWrittenHashUsesPlainTextOnlyForPlainModes() {
        let item = sample(id: "stored-hash", plainText: "hello")
        XCTAssertEqual(PasteboardWriter.writtenHash(for: item, mode: .plainText), ContentHash.text("hello"))
        XCTAssertEqual(PasteboardWriter.writtenHash(for: item, mode: .plainCopy), ContentHash.text("hello"))
        XCTAssertEqual(PasteboardWriter.writtenHash(for: item, mode: .automatic), item.contentHash)
        XCTAssertEqual(PasteboardWriter.writtenHash(for: item, mode: .copyOnly), item.contentHash)
    }

    func testSelfWriteIgnoresSameHashWithinOneSecond() {
        var suppression = SelfWriteSuppression()
        let start = Date(timeIntervalSince1970: 1_000)
        let token = suppression.begin(hash: "hash-a")
        XCTAssertFalse(suppression.shouldIgnore(changeCount: 7, hash: "hash-a", now: start))
        suppression.finish(token: token, changeCount: 7, now: start)
        XCTAssertTrue(suppression.shouldIgnore(changeCount: 7, hash: "hash-a", now: start.addingTimeInterval(0.1)))
        XCTAssertTrue(suppression.shouldIgnore(changeCount: 8, hash: "hash-a", now: start.addingTimeInterval(0.4)))
        XCTAssertFalse(suppression.shouldIgnore(changeCount: 8, hash: "other", now: start.addingTimeInterval(0.2)))
        XCTAssertFalse(suppression.shouldIgnore(changeCount: 6, hash: "hash-a", now: start.addingTimeInterval(0.2)))
        XCTAssertFalse(suppression.shouldIgnore(changeCount: 8, hash: "hash-a", now: start.addingTimeInterval(1)))
    }

    func testSelfWriteWindowsDoNotCancelEachOther() {
        var suppression = SelfWriteSuppression()
        let start = Date(timeIntervalSince1970: 2_000)
        let first = suppression.begin(hash: "hash-a")
        suppression.finish(token: first, changeCount: 10, now: start)
        let second = suppression.begin(hash: "hash-b")
        suppression.finish(token: second, changeCount: 11, now: start.addingTimeInterval(0.2))
        let midway = start.addingTimeInterval(0.5)
        XCTAssertTrue(suppression.shouldIgnore(changeCount: 12, hash: "hash-a", now: midway))
        XCTAssertTrue(suppression.shouldIgnore(changeCount: 13, hash: "hash-b", now: midway))
        XCTAssertFalse(suppression.shouldIgnore(changeCount: 14, hash: "hash-a", now: start.addingTimeInterval(1)))
        XCTAssertTrue(suppression.shouldIgnore(changeCount: 15, hash: "hash-b", now: start.addingTimeInterval(1)))
        XCTAssertFalse(suppression.shouldIgnore(changeCount: 16, hash: "hash-b", now: start.addingTimeInterval(1.2)))
    }

    func testSelfWriteIgnoresSupersetEchoWhenDedupHashChanges() {
        var suppression = SelfWriteSuppression()
        let start = Date(timeIntervalSince1970: 3_000)
        let token = suppression.begin(hash: "rtf-hash", digests: ["rtf-hash", "rtf-bytes"], now: start)
        suppression.finish(token: token, changeCount: 4, now: start)
        XCTAssertTrue(suppression.shouldIgnore(
            changeCount: 5,
            hash: "plain-hash",
            digests: ["rtf-bytes", "plain-hash"],
            now: start.addingTimeInterval(0.3)
        ))
        XCTAssertFalse(suppression.shouldIgnore(
            changeCount: 6,
            hash: "other",
            digests: ["other-bytes"],
            now: start.addingTimeInterval(0.4)
        ))
        XCTAssertTrue(suppression.shouldIgnore(
            changeCount: 5,
            hash: "rtf-bytes",
            digests: [],
            now: start.addingTimeInterval(0.5)
        ))
    }

    func testSelfWriteIgnoresUnknownToken() {
        var suppression = SelfWriteSuppression()
        let now = Date(timeIntervalSince1970: 5_000)
        suppression.finish(token: 99, changeCount: 1, now: now)
        XCTAssertFalse(suppression.shouldIgnore(changeCount: 1, hash: "hash-a", now: now))
    }

    func testSelfWritePrunesExpiredAndUnfinishedMarks() {
        var suppression = SelfWriteSuppression()
        let start = Date(timeIntervalSince1970: 4_000)
        let unfinished = suppression.begin(hash: "pending", now: start)
        suppression.prune(now: start.addingTimeInterval(1))
        suppression.finish(token: unfinished, changeCount: 1, now: start.addingTimeInterval(1))
        XCTAssertFalse(suppression.shouldIgnore(changeCount: 1, hash: "pending", now: start.addingTimeInterval(1)))

        let token = suppression.begin(hash: "kept", now: start)
        suppression.finish(token: token, changeCount: 2, now: start)
        suppression.prune(now: start.addingTimeInterval(1))
        XCTAssertFalse(suppression.shouldIgnore(changeCount: 3, hash: "kept", now: start.addingTimeInterval(1)))
    }

    func testEchoDigestsStillMatchWhenPlainTextIsAdded() throws {
        let rich = Data("rich-a".utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try rich.write(to: directory.appendingPathComponent("payload"))
        let item = sample(id: ContentHash.sha256(rich), plainText: "")
        let stored = StoredRepresentation(uti: PasteboardUTI.rtf, storage: "file", relativePath: "payload", inlineValue: nil)
        let written = PasteboardWriter.writtenEchoDigests(item: item, representations: [stored], directory: directory, mode: .automatic)
        let original = PasteboardSnapshot(items: [PasteboardItemData(values: [PasteboardUTI.rtf: rich])])
        let merged = PasteboardSnapshot(items: [PasteboardItemData(values: [
            PasteboardUTI.rtf: rich,
            PasteboardUTI.plain: Data("hello".utf8)
        ])])
        XCTAssertEqual(CaptureBuilder.build(original)?.contentHash, item.contentHash)
        XCTAssertNotEqual(CaptureBuilder.build(merged)?.contentHash, item.contentHash)
        var readBack = CaptureBuilder.echoDigests(merged)
        readBack.insert(CaptureBuilder.build(merged)?.contentHash ?? "")
        XCTAssertFalse(written.isDisjoint(with: readBack))
    }

    func testEchoDigestsStillContainOriginalImageWhenAnotherEncodingIsAdded() {
        let tiff = Data("tiff-bytes".utf8)
        let png = Data("png-bytes".utf8)
        let original = PasteboardSnapshot(items: [PasteboardItemData(values: [PasteboardUTI.tiff: tiff])])
        let merged = PasteboardSnapshot(items: [PasteboardItemData(values: [
            PasteboardUTI.png: png,
            PasteboardUTI.tiff: tiff
        ])])
        XCTAssertNotEqual(CaptureBuilder.build(original)?.contentHash, CaptureBuilder.build(merged)?.contentHash)
        XCTAssertFalse(CaptureBuilder.echoDigests(original).isDisjoint(with: CaptureBuilder.echoDigests(merged)))
    }

    func testEchoDigestsIncludeTextFilesAndFullDigestsButSkipMarkers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)
        let plist = try PropertyListSerialization.data(fromPropertyList: [file.path], format: .binary, options: 0)
        let plain = Data("hello".utf8)
        let marker = Data("secret".utf8)
        let snapshot = PasteboardSnapshot(items: [PasteboardItemData(
            values: [
                PasteboardUTI.plain: plain,
                PasteboardUTI.filenames: plist,
                PasteboardUTI.concealed: marker,
                PasteboardUTI.fileURL: Data(file.path.utf8)
            ],
            fullDigests: [PasteboardUTI.png: "full-digest"]
        )])
        let digests = CaptureBuilder.echoDigests(snapshot)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = Int64((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        XCTAssertTrue(digests.contains(ContentHash.text("hello")))
        XCTAssertTrue(digests.contains(ContentHash.sha256(plain)))
        XCTAssertTrue(digests.contains("full-digest"))
        XCTAssertTrue(digests.contains(ContentHash.files([FileFingerprint(path: file.path, size: size, modifiedAt: modified)])))
        XCTAssertFalse(digests.contains(ContentHash.sha256(marker)))
        XCTAssertFalse(digests.contains(ContentHash.sha256(plist)))
    }

    func testWrittenEchoDigestsCoverPlainInlineMissingAndSkippedTypes() throws {
        let item = sample(id: "stored-hash", plainText: "hello\r\n")
        XCTAssertEqual(
            PasteboardWriter.writtenEchoDigests(item: item, representations: [], directory: URL(fileURLWithPath: "/tmp"), mode: .plainText),
            [PasteboardWriter.plainHash(for: item)]
        )
        XCTAssertEqual(
            PasteboardWriter.writtenEchoDigests(item: item, representations: [], directory: URL(fileURLWithPath: "/tmp"), mode: .plainCopy),
            [ContentHash.text("hello\n")]
        )

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let utf16 = try XCTUnwrap("你好".data(using: .utf16))
        try utf16.write(to: directory.appendingPathComponent("utf16"))
        let badUTF8 = Data([0xff])
        let badUTF16 = Data([0xff])
        try badUTF8.write(to: directory.appendingPathComponent("bad-utf8"))
        try badUTF16.write(to: directory.appendingPathComponent("bad-utf16"))
        let fakeImage = Data("not-an-image".utf8)
        try fakeImage.write(to: directory.appendingPathComponent("pic"))
        let representations = [
            StoredRepresentation(uti: PasteboardUTI.plain, storage: "inline", relativePath: nil, inlineValue: "hello"),
            StoredRepresentation(uti: PasteboardUTI.url, storage: "inline", relativePath: nil, inlineValue: "https://example.com"),
            StoredRepresentation(uti: PasteboardUTI.utf16, storage: "file", relativePath: "utf16", inlineValue: nil),
            StoredRepresentation(uti: PasteboardUTI.plain, storage: "file", relativePath: "bad-utf8", inlineValue: nil),
            StoredRepresentation(uti: PasteboardUTI.utf16, storage: "file", relativePath: "bad-utf16", inlineValue: nil),
            StoredRepresentation(uti: PasteboardUTI.tiff, storage: "file", relativePath: "pic", inlineValue: nil),
            StoredRepresentation(uti: PasteboardUTI.plain, storage: "file", relativePath: "missing", inlineValue: nil),
            StoredRepresentation(uti: PasteboardUTI.rtf, storage: "inline", relativePath: nil, inlineValue: nil),
            StoredRepresentation(uti: PasteboardUTI.fileURL, storage: "inline", relativePath: nil, inlineValue: "/tmp/a"),
            StoredRepresentation(uti: PasteboardUTI.filenames, storage: "inline", relativePath: nil, inlineValue: "/tmp/a"),
            StoredRepresentation(uti: PasteboardUTI.concealed, storage: "inline", relativePath: nil, inlineValue: "secret")
        ]
        let digests = PasteboardWriter.writtenEchoDigests(item: item, representations: representations, directory: directory, mode: .automatic)
        XCTAssertTrue(digests.contains(item.contentHash))
        XCTAssertTrue(digests.contains(ContentHash.text("hello")))
        XCTAssertTrue(digests.contains(ContentHash.sha256(Data("hello".utf8))))
        XCTAssertTrue(digests.contains(ContentHash.text("https://example.com")))
        XCTAssertTrue(digests.contains(ContentHash.text("你好")))
        XCTAssertTrue(digests.contains(ContentHash.sha256(utf16)))
        XCTAssertTrue(digests.contains(ContentHash.sha256(badUTF8)))
        XCTAssertTrue(digests.contains(ContentHash.sha256(badUTF16)))
        XCTAssertNil(String(data: badUTF8, encoding: .utf8))
        let decodedUTF16 = String(data: badUTF16, encoding: .utf16)
        XCTAssertTrue(decodedUTF16 == nil || decodedUTF16?.isEmpty == true)
        XCTAssertTrue(digests.contains(ContentHash.imageData(fakeImage)))
        XCTAssertNil(ContentHash.canonicalImage(fakeImage))
        XCTAssertFalse(digests.contains(ContentHash.sha256(Data("/tmp/a".utf8))))
        XCTAssertFalse(digests.contains(ContentHash.sha256(Data("secret".utf8))))
    }

    func testCanonicalImageMatchesPNGAndTIFFAndJoinsEchoDigests() throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 8,
            bitsPerPixel: 32
        ), let pixels = rep.bitmapData else {
            XCTFail("Could not allocate a bitmap")
            return
        }
        for index in 0..<(2 * 8) {
            let byte = UInt8((index * 37) % 251)
            pixels[index] = index % 4 == 3 ? 255 : byte
        }
        let tiff = try XCTUnwrap(rep.tiffRepresentation)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let tiffDigest = try XCTUnwrap(ContentHash.canonicalImage(tiff))
        let pngDigest = try XCTUnwrap(ContentHash.canonicalImage(png))
        XCTAssertEqual(tiffDigest, pngDigest)
        XCTAssertEqual(ContentHash.canonicalImage(tiff), tiffDigest)
        XCTAssertNil(ContentHash.canonicalImage(Data()))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try png.write(to: directory.appendingPathComponent("shot.png"))
        let item = sample(id: ContentHash.imageData(png), kind: .image, plainText: "")
        let stored = StoredRepresentation(uti: PasteboardUTI.png, storage: "file", relativePath: "shot.png", inlineValue: nil)
        let written = PasteboardWriter.writtenEchoDigests(item: item, representations: [stored], directory: directory, mode: .copyOnly)
        XCTAssertTrue(written.contains(pngDigest))
        let readBack = CaptureBuilder.echoDigests(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.tiff: tiff, PasteboardUTI.png: png])
        ]))
        XCTAssertTrue(readBack.contains(tiffDigest))
        XCTAssertFalse(written.isDisjoint(with: readBack))
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

    func testNarrowPanelPlacesPreviewBelowTheList() {
        XCTAssertTrue(HistoryPanelLayout.placesPreviewBelowList(containerWidth: 640))
        XCTAssertTrue(HistoryPanelLayout.placesPreviewBelowList(containerWidth: 719))
        XCTAssertFalse(HistoryPanelLayout.placesPreviewBelowList(containerWidth: 720))
        XCTAssertFalse(HistoryPanelLayout.placesPreviewBelowList(containerWidth: 960))
        XCTAssertEqual(HistoryPanelLayout.previewHeight(in: 400), 168, accuracy: 0.001)
        XCTAssertEqual(HistoryPanelLayout.previewHeight(in: 200), 110, accuracy: 0.001)
        XCTAssertEqual(HistoryPanelLayout.previewHeight(in: 1000), 420, accuracy: 0.001)
    }

    func testGroupingPlacesRecentUnpinnedInJustNow() {
        let item = sample(id: "1", lastUsedAt: Date())
        XCTAssertEqual(HistoryGrouping.section(for: item), .justNow)
        var pinned = item
        pinned.pinned = true
        XCTAssertEqual(HistoryGrouping.section(for: pinned), .pinned)
    }

    func testDeleteKeyOnPinnedItemPresentsConfirmation() {
        var session = ItemDeleteSession()
        XCTAssertEqual(session.request(selectedID: "pin", isPinned: true), .confirmPinned(id: "pin"))
        XCTAssertTrue(session.confirmationPresented)
        XCTAssertEqual(session.pendingID, "pin")
        XCTAssertTrue(ItemDeleteRequest.confirmPinned(id: "pin").clearsBanner)

        var plain = ItemDeleteSession()
        XCTAssertEqual(plain.request(selectedID: "text", isPinned: false), .deleteNow(id: "text"))
        XCTAssertFalse(plain.confirmationPresented)
        XCTAssertNil(plain.pendingID)
        XCTAssertFalse(ItemDeleteRequest.deleteNow(id: "text").clearsBanner)

        var missing = ItemDeleteSession()
        XCTAssertEqual(missing.request(selectedID: nil, isPinned: true), .ignored)
        XCTAssertFalse(missing.confirmationPresented)
    }

    func testPinnedConfirmationDeletesTheItemThatOpenedTheDialog() {
        var session = ItemDeleteSession()
        _ = session.request(selectedID: "pin", isPinned: true)
        XCTAssertEqual(session.confirm(), "pin")
        XCTAssertFalse(session.confirmationPresented)
        XCTAssertNil(session.pendingID)
        XCTAssertNil(session.confirm())
    }

    func testAppearanceChoiceMapsToWindowAppearance() {
        XCTAssertNil(AppearanceChoice.system.nsAppearance)
        XCTAssertEqual(AppearanceChoice.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceChoice.dark.nsAppearance?.name, .darkAqua)
    }

    @MainActor
    func testChangingAppearanceNotifiesOpenWindows() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        var applied = 0
        harness.model.settings.onAppearanceChange = { applied += 1 }
        let current = harness.model.settings.appearance
        harness.model.settings.appearance = current
        XCTAssertEqual(applied, 0)
        let next: AppearanceChoice = current == .dark ? .light : .dark
        harness.model.settings.appearance = next
        XCTAssertEqual(applied, 1)
        harness.model.settings.appearance = .system
        XCTAssertEqual(applied, 2)
    }

    func testCancelDropsPendingPinnedDelete() {
        var session = ItemDeleteSession()
        _ = session.request(selectedID: "pin", isPinned: true)
        session.cancel()
        XCTAssertFalse(session.confirmationPresented)
        XCTAssertNil(session.pendingID)
        XCTAssertNil(session.confirm())
    }

    func testPinnedDeleteConfirmationYieldsKeysLikeClearAll() {
        XCTAssertTrue(ItemDeleteRouting.yieldsKeysToConfirmation(confirmClearAll: false, confirmPinnedDelete: true))
        XCTAssertTrue(ItemDeleteRouting.yieldsKeysToConfirmation(confirmClearAll: true, confirmPinnedDelete: false))
        XCTAssertTrue(ItemDeleteRouting.yieldsKeysToConfirmation(confirmClearAll: true, confirmPinnedDelete: true))
        XCTAssertFalse(ItemDeleteRouting.yieldsKeysToConfirmation(confirmClearAll: false, confirmPinnedDelete: false))
    }

    @MainActor
    func testModelPinnedDeleteKeepsTheItemUntilTheOriginalOneIsConfirmed() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        let pinned = try harness.insert("pinned-body")
        let other = try harness.insert("other-body")
        try model.store.setPinned(id: pinned.id, pinned: true)
        model.reload()
        model.selectedID = pinned.id
        model.banner = "旧提示"

        model.deleteSelected()

        XCTAssertTrue(model.confirmPinnedDelete)
        XCTAssertEqual(model.pendingPinnedDeleteID, pinned.id)
        XCTAssertNil(model.banner)
        XCTAssertEqual(try model.store.count(), 2)

        model.selectedID = other.id
        model.deletePinned(id: model.pendingPinnedDeleteID)

        let remaining = try model.store.fetchAll().map(\.id)
        XCTAssertEqual(remaining, [other.id])
        XCTAssertFalse(model.confirmPinnedDelete)
        XCTAssertNil(model.pendingPinnedDeleteID)
    }

    @MainActor
    func testModelUnpinnedDeleteRemovesTheItemWithoutConfirmation() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        let item = try harness.insert("plain-body")
        model.reload()
        model.selectedID = item.id
        model.banner = "旧提示"

        model.deleteSelected()

        XCTAssertFalse(model.confirmPinnedDelete)
        XCTAssertNil(model.pendingPinnedDeleteID)
        XCTAssertEqual(try model.store.count(), 0)
        XCTAssertEqual(model.banner, L10n.text("已删除，⌘Z 撤销", "Deleted. Press ⌘Z to undo."))
    }

    @MainActor
    func testClosingThePanelDropsSingleDeleteUndo() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        let item = try harness.insert("undo-body")
        model.reload()
        model.selectedID = item.id
        let panel = PanelController(model: model)
        defer { panel.closePanel() }
        panel.show(placement: .center)

        model.deleteSelected()
        model.undoDelete()

        XCTAssertEqual(try model.store.fetchAll().map(\.plainText), ["undo-body"])

        model.selectedID = model.items.first?.id
        model.deleteSelected()
        panel.closePanel()
        model.undoDelete()

        XCTAssertEqual(try model.store.count(), 0)
    }

    @MainActor
    func testModelCancelPinnedDeleteLeavesTheItem() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        let pinned = try harness.insert("pinned-cancel")
        try model.store.setPinned(id: pinned.id, pinned: true)
        model.reload()
        model.selectedID = pinned.id
        model.deleteSelected()
        model.cancelPinnedDelete()
        model.deletePinned(id: nil)

        XCTAssertFalse(model.confirmPinnedDelete)
        XCTAssertNil(model.pendingPinnedDeleteID)
        XCTAssertEqual(try model.store.fetchAll().map(\.id), [pinned.id])
    }

    @MainActor
    func testClearAllFailureNoticeStaysWhileItemsRemain() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        _ = try harness.insert("still-here")
        model.reload()
        model.clearAllError = AppModel.clearAllFailedMessage
        model.banner = AppModel.clearAllFailedMessage

        model.reload()

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.clearAllError, AppModel.clearAllFailedMessage)
        XCTAssertEqual(model.banner, AppModel.clearAllFailedMessage)
    }

    @MainActor
    func testSettingsClearFailureKeepsHistoryAndSetsNotice() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        _ = try harness.insert("kept")
        model.reload()
        model.banner = "其他提示"
        try installClearBlocker(at: harness.directory)

        model.clearAllFromSettings()

        XCTAssertEqual(try model.store.count(), 1)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.clearAllError, AppModel.clearAllFailedMessage)
        XCTAssertEqual(model.banner, "其他提示")
    }

    @MainActor
    func testSettingsClearSuccessRemovesFailureNotices() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        _ = try harness.insert("gone")
        model.reload()
        model.clearAllError = AppModel.clearAllFailedMessage
        model.banner = AppModel.clearAllFailedMessage

        model.clearAllFromSettings()

        XCTAssertEqual(try model.store.count(), 0)
        XCTAssertNil(model.clearAllError)
        XCTAssertNil(model.banner)
    }

    @MainActor
    func testPanelClearFailureSetsBannerAndKeepsSettingsNotice() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        _ = try harness.insert("kept")
        model.reload()
        model.clearAllError = AppModel.clearAllFailedMessage
        try installClearBlocker(at: harness.directory)

        model.clearAllFromPanel()

        XCTAssertEqual(try model.store.count(), 1)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.banner, AppModel.clearAllFailedMessage)
        XCTAssertEqual(model.clearAllError, AppModel.clearAllFailedMessage)
    }

    @MainActor
    func testPanelClearSuccessKeepsUnrelatedBanner() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        _ = try harness.insert("gone")
        model.reload()
        model.clearAllError = AppModel.clearAllFailedMessage
        model.banner = "其他提示"

        model.clearAllFromPanel()

        XCTAssertEqual(try model.store.count(), 0)
        XCTAssertNil(model.clearAllError)
        XCTAssertEqual(model.banner, "其他提示")
    }

    @MainActor
    func testReloadFailureKeepsClearAllFailureNotice() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        _ = try harness.insert("kept")
        model.reload()
        model.clearAllError = AppModel.clearAllFailedMessage
        model.banner = AppModel.clearAllFailedMessage
        try dropItemsTable(at: harness.directory)

        model.reload()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.clearAllError, AppModel.clearAllFailedMessage)
        XCTAssertEqual(model.banner, AppModel.clearAllFailedMessage)
    }

    func testPauseHotkeyPlanCoversSkipConflictAndBothSidesOfTheChord() {
        XCTAssertEqual(fourChar(""), 0)
        XCTAssertEqual(fourChar("C"), 0x43)
        XCTAssertEqual(fourChar("CLAP"), 0x434C4150)
        XCTAssertEqual(fourChar("CLAPX"), fourChar("CLAP"))
        XCTAssertEqual(
            HotkeyPlan.pause(code: 9, modifiers: 768, display: "", panelCode: 9, panelModifiers: 768),
            .skip
        )
        XCTAssertEqual(
            HotkeyPlan.pause(code: 9, modifiers: 768, display: "⌘⇧V", panelCode: 9, panelModifiers: 768),
            .conflict
        )
        XCTAssertEqual(
            HotkeyPlan.pause(code: 9, modifiers: 256, display: "⌘V", panelCode: 9, panelModifiers: 768),
            .register(keyCode: 9, modifiers: 256)
        )
        XCTAssertEqual(
            HotkeyPlan.pause(code: 35, modifiers: 768, display: "⌘⇧P", panelCode: 9, panelModifiers: 768),
            .register(keyCode: 35, modifiers: 768)
        )
        XCTAssertFalse(HotkeyPlan.duplicates(recording: .panel, code: 35, modifiers: 768, panelCode: 9, panelModifiers: 768, pauseCode: 0, pauseModifiers: 0, pauseIsSet: false))
        XCTAssertFalse(HotkeyPlan.duplicates(recording: .panel, code: 35, modifiers: 768, panelCode: 9, panelModifiers: 768, pauseCode: 35, pauseModifiers: 256, pauseIsSet: true))
        XCTAssertFalse(HotkeyPlan.duplicates(recording: .panel, code: 35, modifiers: 768, panelCode: 9, panelModifiers: 768, pauseCode: 36, pauseModifiers: 768, pauseIsSet: true))
        XCTAssertTrue(HotkeyPlan.duplicates(recording: .panel, code: 35, modifiers: 768, panelCode: 9, panelModifiers: 768, pauseCode: 35, pauseModifiers: 768, pauseIsSet: true))
        XCTAssertFalse(HotkeyPlan.duplicates(recording: .pause, code: 35, modifiers: 768, panelCode: 9, panelModifiers: 768, pauseCode: 35, pauseModifiers: 768, pauseIsSet: true))
        XCTAssertTrue(HotkeyPlan.duplicates(recording: .pause, code: 9, modifiers: 768, panelCode: 9, panelModifiers: 768, pauseCode: 0, pauseModifiers: 0, pauseIsSet: false))
    }

    func testPauseHotkeyDefaultsToUnsetAndRoundTripsWhenSaved() {
        let suite = "pause-hotkey-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.pauseHotkeyIsSet)
        XCTAssertEqual(settings.pauseHotkeyDisplay, "")
        XCTAssertEqual(settings.pauseHotkeyCode, 0)
        XCTAssertEqual(settings.pauseHotkeyModifiers, 0)
        XCTAssertEqual(settings.hotkeyDisplay, "⌘⇧V")
        XCTAssertFalse(settings.isPaused)
        settings.pauseHotkeyCode = 35
        settings.pauseHotkeyModifiers = 768
        settings.pauseHotkeyDisplay = "⌘⇧P"
        settings.pauseHotkeyConflict = true
        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.pauseHotkeyIsSet)
        XCTAssertEqual(restored.pauseHotkeyCode, 35)
        XCTAssertEqual(restored.pauseHotkeyModifiers, 768)
        XCTAssertEqual(restored.pauseHotkeyDisplay, "⌘⇧P")
        XCTAssertFalse(restored.pauseHotkeyConflict)
    }

    func testRefreshPauseClearsOnlyExpiredDeadlines() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pause-refresh-\(UUID().uuidString)")!)
        var redraws = 0
        settings.onPauseStateChange = { redraws += 1 }
        settings.manuallyPaused = true
        settings.refreshPause()
        XCTAssertTrue(settings.isPaused)
        XCTAssertEqual(redraws, 0)
        settings.pauseUntil = Date().addingTimeInterval(60)
        settings.refreshPause()
        XCTAssertTrue(settings.manuallyPaused)
        XCTAssertEqual(redraws, 0)
        settings.pauseUntil = Date().addingTimeInterval(-1)
        settings.refreshPause(notify: false)
        XCTAssertFalse(settings.isPaused)
        XCTAssertNil(settings.pauseUntil)
        XCTAssertFalse(settings.manuallyPaused)
        XCTAssertEqual(redraws, 0)
        settings.pauseUntil = Date().addingTimeInterval(-1)
        settings.manuallyPaused = true
        settings.refreshPause()
        XCTAssertFalse(settings.isPaused)
        XCTAssertEqual(redraws, 1)
    }

    func testStatusClickOpensPermissionGuideUntilTrusted() {
        XCTAssertEqual(StatusItemInteraction.destination(accessibilityTrusted: false), .permissionGuide)
        XCTAssertEqual(StatusItemInteraction.destination(accessibilityTrusted: true), .menu)
        XCTAssertTrue(StatusItemInteraction.isAlternateClick(rightButton: true, control: false))
        XCTAssertTrue(StatusItemInteraction.isAlternateClick(rightButton: false, control: true))
        XCTAssertFalse(StatusItemInteraction.isAlternateClick(rightButton: false, control: false))
        XCTAssertEqual(
            StatusItemInteraction.effect(accessibilityTrusted: false, alternateClick: false),
            .permissionGuide
        )
        XCTAssertEqual(
            StatusItemInteraction.effect(accessibilityTrusted: false, alternateClick: true),
            .menu
        )
        XCTAssertEqual(
            StatusItemInteraction.effect(accessibilityTrusted: true, alternateClick: false),
            .menu
        )
        XCTAssertEqual(
            StatusItemInteraction.effect(accessibilityTrusted: true, alternateClick: true),
            .menu
        )
        XCTAssertTrue(StatusItemInteraction.isAlternateClick(rightButton: true, control: true))
    }

    func testPermissionGuideQuotesManualPasteInEachLanguage() {
        XCTAssertTrue(PermissionGuideCopy.historyNoteZH.contains(PasteOutcome.manualPasteMessageZH))
        XCTAssertFalse(PermissionGuideCopy.historyNoteZH.contains(PasteOutcome.manualPasteMessageEN))
        XCTAssertTrue(PermissionGuideCopy.historyNoteEN.contains(PasteOutcome.manualPasteMessageEN))
        XCTAssertFalse(PermissionGuideCopy.historyNoteEN.contains(PasteOutcome.manualPasteMessageZH))
        XCTAssertEqual(
            PermissionGuideCopy.historyNote,
            L10n.text(PermissionGuideCopy.historyNoteZH, PermissionGuideCopy.historyNoteEN)
        )
        XCTAssertEqual(
            PasteOutcome.manualPasteMessage,
            L10n.text(PasteOutcome.manualPasteMessageZH, PasteOutcome.manualPasteMessageEN)
        )
        XCTAssertEqual(PermissionGuideCopy.usableHeight(intrinsic: 300, preferred: 500), 300)
        XCTAssertEqual(PermissionGuideCopy.usableHeight(intrinsic: -1, preferred: 420), 420)
        XCTAssertEqual(PermissionGuideCopy.usableHeight(intrinsic: 10, preferred: 900), 360)
        XCTAssertEqual(PermissionGuideCopy.usableHeight(intrinsic: 220, preferred: 10), 220)
        XCTAssertEqual(PermissionGuideCopy.usableHeight(intrinsic: 640, preferred: 10), 640)
        XCTAssertEqual(PermissionGuideCopy.usableHeight(intrinsic: 219, preferred: 640), 640)
        XCTAssertEqual(PermissionGuideCopy.usableHeight(intrinsic: 641, preferred: 220), 220)
        XCTAssertEqual(PermissionGuideCopy.usableHeight(intrinsic: 641, preferred: 219), 360)
        XCTAssertEqual(PermissionGuideCopy.usableHeight(intrinsic: .nan, preferred: .infinity), 360)
        XCTAssertEqual(PermissionGuideCopy.width, 460)
    }

    func testPermissionGuideLayoutClampsEveryEdge() {
        let window = NSRect(x: 0, y: 0, width: 100, height: 40)
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let fitted = PermissionGuideLayout.frame(
            window: window,
            buttonFrame: NSRect(x: 200, y: 500, width: 20, height: 20),
            visible: nil
        )
        XCTAssertEqual(fitted, NSRect(x: 160, y: 454, width: 100, height: 40))
        XCTAssertEqual(
            PermissionGuideLayout.frame(
                window: window,
                buttonFrame: NSRect(x: 200, y: 500, width: 20, height: 20),
                visible: visible
            ),
            NSRect(x: 160, y: 454, width: 100, height: 40)
        )
        XCTAssertEqual(
            PermissionGuideLayout.frame(
                window: window,
                buttonFrame: NSRect(x: 970, y: 500, width: 20, height: 20),
                visible: visible
            ).origin.x,
            896
        )
        XCTAssertEqual(
            PermissionGuideLayout.frame(
                window: window,
                buttonFrame: NSRect(x: 0, y: 500, width: 20, height: 20),
                visible: visible
            ).origin.x,
            4
        )
        let tall = PermissionGuideLayout.frame(
            window: NSRect(x: 0, y: 0, width: 100, height: 200),
            buttonFrame: NSRect(x: 200, y: 100, width: 20, height: 20),
            visible: NSRect(x: 0, y: 0, width: 1000, height: 100)
        )
        XCTAssertEqual(tall.size.height, 100)
        XCTAssertEqual(tall.origin.y, 0)
        let above = PermissionGuideLayout.frame(
            window: window,
            buttonFrame: NSRect(x: 200, y: 200, width: 20, height: 20),
            visible: NSRect(x: 0, y: 0, width: 1000, height: 100)
        )
        XCTAssertEqual(above, NSRect(x: 160, y: 60, width: 100, height: 40))
    }

    @MainActor
    func testPermissionGuideViewRendersBothActions() {
        var settings = 0
        var panels = 0
        let view = PermissionGuideView(onOpenSettings: { settings += 1 }, onOpenPanel: { panels += 1 })
        _ = view.body
        view.onOpenSettings()
        view.onOpenPanel()
        XCTAssertEqual(settings, 1)
        XCTAssertEqual(panels, 1)
    }

    func testAccessibilityPromptOptionsAndStubbedOpen() {
        XCTAssertNil(AccessibilityClient.promptOptions(false))
        let prompted = AccessibilityClient.promptOptions(true)
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        XCTAssertEqual((prompted as NSDictionary?)?[promptKey] as? Bool, true)
        _ = AccessibilityClient.readTrusted(nil)
        _ = AccessibilityClient.readTrusted([promptKey: false] as CFDictionary)
        let query = AccessibilityClient.queryTrusted
        let activate = AccessibilityClient.activateApp
        let open = AccessibilityClient.openURL
        defer {
            AccessibilityClient.queryTrusted = query
            AccessibilityClient.activateApp = activate
            AccessibilityClient.openURL = open
        }
        _ = query(false)
        activate()
        var prompts: [Bool] = []
        var urls: [URL] = []
        var activations = 0
        AccessibilityClient.queryTrusted = { prompt in
            prompts.append(prompt)
            return prompt
        }
        AccessibilityClient.activateApp = { activations += 1 }
        AccessibilityClient.openURL = { urls.append($0) }
        XCTAssertTrue(AccessibilityClient.promptAndOpenSettings())
        AccessibilityClient.queryTrusted = { prompt in
            prompts.append(prompt)
            return false
        }
        XCTAssertFalse(AccessibilityClient.promptAndOpenSettings())
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(prompts, [true, true])
        XCTAssertEqual(urls, [AccessibilityClient.settingsURL, AccessibilityClient.settingsURL])
    }

    @MainActor
    func testAccessibilitySettingsButtonsRefreshTrust() throws {
        let query = AccessibilityClient.queryTrusted
        let activate = AccessibilityClient.activateApp
        let open = AccessibilityClient.openURL
        AccessibilityClient.activateApp = {}
        AccessibilityClient.openURL = { _ in }
        AccessibilityClient.queryTrusted = { _ in false }
        let harness = try deleteHarness()
        var windows: [NSWindow] = []
        defer {
            for window in windows {
                window.orderOut(nil)
                window.contentViewController = nil
            }
            harness.cleanup()
            AccessibilityClient.queryTrusted = query
            AccessibilityClient.activateApp = activate
            AccessibilityClient.openURL = open
        }

        harness.model.accessibilityTrusted = true
        windows.append(attachForRender(HistoryPanelView().environmentObject(harness.model)))
        harness.model.accessibilityTrusted = false
        windows.append(attachForRender(HistoryPanelView().environmentObject(harness.model)))
        AccessibilityClient.queryTrusted = { _ in true }
        windows.append(attachForRender(SettingsView(initialTab: .about).environmentObject(harness.model)))
        AccessibilityClient.queryTrusted = { _ in false }
        windows.append(attachForRender(SettingsView(initialTab: .about).environmentObject(harness.model)))
        flushMain()

        var opened: [URL] = []
        var prompts: [Bool] = []
        AccessibilityClient.openURL = { opened.append($0) }
        harness.model.openAccessibilitySettings()
        XCTAssertEqual(opened, [AccessibilityClient.settingsURL])
        XCTAssertFalse(harness.model.accessibilityTrusted)
        AccessibilityClient.queryTrusted = { prompt in
            prompts.append(prompt)
            return true
        }
        harness.model.openAccessibilitySettings()
        XCTAssertEqual(prompts, [true, false])
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(harness.model.accessibilityTrusted)
        harness.model.openAccessibilitySettings()
        XCTAssertEqual(prompts, [true, false, true, false])
        XCTAssertEqual(opened.count, 3)
        XCTAssertTrue(harness.model.accessibilityTrusted)
    }

    @MainActor
    func testStatusIconDrawsPauseSlashAndTrustDot() {
        for paused in [false, true] {
            for trusted in [false, true] {
                let image = StatusIcon.image(paused: paused, trusted: trusted)
                XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
                XCTAssertTrue(image.isTemplate)
                let canvas = NSImage(size: image.size)
                canvas.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: image.size))
                canvas.unlockFocus()
            }
        }
    }

    @MainActor
    func testStatusItemCoversGuideMenuClicksAndPolling() throws {
        let query = AccessibilityClient.queryTrusted
        let activate = AccessibilityClient.activateApp
        let open = AccessibilityClient.openURL
        let interval = StatusItemController.trustPollInterval
        StatusItemController.trustPollInterval = 0.05
        AccessibilityClient.queryTrusted = { _ in false }
        AccessibilityClient.activateApp = {}
        AccessibilityClient.openURL = { _ in }
        let harness = try deleteHarness()
        let panel = PanelController(model: harness.model)
        let controller = StatusItemController(model: harness.model, panel: panel)
        defer {
            panel.closePanel()
            controller.removeFromStatusBar()
            harness.cleanup()
            AccessibilityClient.queryTrusted = query
            AccessibilityClient.activateApp = activate
            AccessibilityClient.openURL = open
            StatusItemController.trustPollInterval = interval
        }

        harness.model.settings.appearance = .dark
        harness.model.settings.appearance = .light
        harness.model.settings.appearance = .system

        let spyMenu = TrackingMenu()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 16))
        controller.presentAlternateMenu(spyMenu, nil, anchor, 4)
        XCTAssertEqual(spyMenu.points, [NSPoint(x: 0, y: 4)])
        let event = try XCTUnwrap(Self.mouseEvent(type: .leftMouseUp, location: NSPoint(x: 3, y: 5), flags: []))
        controller.presentAlternateMenu(spyMenu, event, anchor, 4)
        XCTAssertEqual(spyMenu.points, [NSPoint(x: 0, y: 4), anchor.convert(event.locationInWindow, from: nil)])

        var sawDefaultClick = false
        controller.presentAlternateMenu = { _, _, _, _ in sawDefaultClick = true }
        controller.showAlternateMenu(from: NSButton(frame: NSRect(x: 0, y: 0, width: 8, height: 8)))
        XCTAssertTrue(sawDefaultClick)

        let spyButton = TrackingButton()
        controller.performPrimaryClick(spyButton)
        XCTAssertEqual(spyButton.clicks, 1)

        let polled = expectation(description: "trust poll")
        let installed = harness.model.onAccessibilityChange
        var fulfilled = false
        harness.model.onAccessibilityChange = { trusted in
            installed?(trusted)
            if trusted, !fulfilled {
                fulfilled = true
                controller.stopTrustPolling()
                polled.fulfill()
            }
        }
        AccessibilityClient.queryTrusted = { _ in true }
        wait(for: [polled], timeout: 2)
        XCTAssertTrue(harness.model.accessibilityTrusted)
        controller.stopTrustPolling()
        StatusItemController.trustPollInterval = 10_000
        controller.startTrustTimer()
        controller.startTrustTimer()
        controller.stopTrustPolling()
        StatusItemController.trustPollInterval = 0.05
        AccessibilityClient.queryTrusted = { _ in false }
        harness.model.refreshAccessibility()
        XCTAssertFalse(harness.model.accessibilityTrusted)

        let menu = NSMenu()
        controller.menuWillOpen(menu)
        XCTAssertEqual(menu.items.first?.isEnabled, false)
        XCTAssertEqual(menu.items.first?.title, L10n.text("暂无记录", "No history"))
        let quit = try XCTUnwrap(menu.items.last { $0.action == NSSelectorFromString("quit") })
        XCTAssertEqual(quit.title, L10n.text("退出", "Quit"))
        XCTAssertEqual(quit.keyEquivalent, "q")
        var didQuit = false
        controller.terminate = { didQuit = true }
        XCTAssertTrue(NSApp.sendAction(quit.action!, to: quit.target, from: quit))
        XCTAssertTrue(didQuit)
        for index in 0..<11 {
            _ = try harness.insert("row-\(index)")
        }
        harness.model.settings.pauseHotkeyDisplay = "⌘⇧P"
        harness.model.settings.pauseHotkeyConflict = false
        controller.menuWillOpen(menu)
        let recent = menu.items.prefix { !$0.isSeparatorItem }
        XCTAssertEqual(recent.count, 10)
        let pause = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("togglePause") })
        XCTAssertEqual(pause.title, StatusMenuText.pauseItem(isPaused: false, hotkeyDisplay: "⌘⇧P", available: true))
        harness.model.settings.pauseHotkeyConflict = true
        controller.menuWillOpen(menu)
        let conflicted = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("togglePause") })
        XCTAssertEqual(conflicted.title, StatusMenuText.pauseItem(isPaused: false, hotkeyDisplay: "⌘⇧P", available: false))

        let pasted = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("pasteRecent:") })
        pasted.representedObject = 1
        NSApp.sendAction(pasted.action!, to: pasted.target, from: pasted)
        pasted.representedObject = "missing-id"
        NSApp.sendAction(pasted.action!, to: pasted.target, from: pasted)

        NSApp.sendAction(pause.action!, to: pause.target, from: pause)
        XCTAssertTrue(harness.model.settings.isPaused)
        NSApp.sendAction(pause.action!, to: pause.target, from: pause)
        XCTAssertFalse(harness.model.settings.isPaused)

        AccessibilityClient.queryTrusted = { _ in true }
        controller.menuWillOpen(menu)
        AccessibilityClient.queryTrusted = { _ in false }
        controller.menuDidClose(menu)
        let closed = expectation(description: "menu closed")
        DispatchQueue.main.async {
            DispatchQueue.main.async { closed.fulfill() }
        }
        wait(for: [closed], timeout: 1)

        controller.clickEvent = { nil }
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("statusClicked"), to: controller, from: nil))
        let leftUp = try XCTUnwrap(Self.mouseEvent(type: .leftMouseUp, location: .zero, flags: []))
        controller.clickEvent = { leftUp }
        controller.handleStatusClick()
        var anchors: [CGFloat] = []
        controller.presentAlternateMenu = { _, _, _, y in anchors.append(y) }
        let rightUp = try XCTUnwrap(Self.mouseEvent(type: .rightMouseUp, location: .zero, flags: []))
        let rightDown = try XCTUnwrap(Self.mouseEvent(type: .rightMouseDown, location: .zero, flags: []))
        let controlClick = try XCTUnwrap(Self.mouseEvent(type: .leftMouseUp, location: .zero, flags: [.control]))
        controller.clickEvent = { rightUp }
        controller.handleStatusClick()
        controller.clickEvent = { rightDown }
        controller.handleStatusClick()
        controller.clickEvent = { controlClick }
        controller.handleStatusClick()
        controller.showAlternateMenu(from: nil)
        let flipped = FlippedButton(frame: NSRect(x: 0, y: 0, width: 12, height: 18))
        controller.showAlternateMenu(from: flipped)
        let plain = NSButton(frame: NSRect(x: 0, y: 0, width: 12, height: 14))
        controller.showAlternateMenu(from: plain)
        let plainAnchor = plain.isFlipped ? plain.bounds.height : plain.bounds.minY
        XCTAssertEqual(Array(anchors.suffix(2)), [CGFloat(18), plainAnchor])

        var primary = 0
        controller.performPrimaryClick = { _ in
            primary += 1
            controller.menuWillOpen(NSMenu())
        }
        AccessibilityClient.queryTrusted = { _ in true }
        controller.clickEvent = { nil }
        controller.handleStatusClick()
        XCTAssertEqual(primary, 1)
        controller.clickEvent = { rightUp }
        controller.handleStatusClick()
        controller.clickEvent = { nil }
        controller.showPrimaryMenu(clicking: nil)
        controller.menuDidClose(NSMenu())
        wait(for: [expectationClosed()], timeout: 1)
        controller.performPrimaryClick = { _ in primary += 1 }
        controller.showPrimaryMenu(clicking: plain)
        XCTAssertGreaterThan(primary, 1)
        AccessibilityClient.queryTrusted = { _ in false }
        harness.model.refreshAccessibility()
        controller.showPrimaryMenu(clicking: plain)
        XCTAssertGreaterThan(primary, 2)

        let guide = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        controller.place(guide, anchorButton: nil, anchorWindow: nil)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView?.addSubview(plain)
        controller.place(guide, anchorButton: plain, anchorWindow: nil)
        controller.place(guide, anchorButton: plain, anchorWindow: host)

        var opened: [URL] = []
        AccessibilityClient.openURL = { opened.append($0) }
        AccessibilityClient.queryTrusted = { _ in false }
        let openGuideSettings = try XCTUnwrap(controller.guideOpenSettings)
        openGuideSettings()
        XCTAssertEqual(opened, [AccessibilityClient.settingsURL])
        let openGuidePanel = try XCTUnwrap(controller.guideOpenPanel)
        openGuidePanel()
        harness.model.onHotkey?()
        harness.model.onHotkey?()
        harness.model.onHotkey?()

        let settingsItem = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("openSettings") })
        NSApp.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem)
        NSApp.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem)
        let openItem = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("openPanel") })
        NSApp.sendAction(openItem.action!, to: openItem.target, from: openItem)
        harness.model.settings.appearance = harness.model.settings.appearance == .dark ? .light : .dark
        harness.model.settings.appearance = .system
    }

    @MainActor
    func testCommandQQuitsThroughTheSameActionAsTheMenu() throws {
        let harness = try deleteHarness()
        let panel = PanelController(model: harness.model)
        let controller = StatusItemController(model: harness.model, panel: panel)
        var quits = 0
        controller.terminate = { quits += 1 }
        defer {
            panel.closePanel()
            controller.removeFromStatusBar()
            harness.cleanup()
        }

        let menu = NSMenu()
        controller.menuWillOpen(menu)
        let quit = try XCTUnwrap(menu.items.last { $0.action == NSSelectorFromString("quit") })
        XCTAssertEqual(quit.title, L10n.text("退出", "Quit"))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertTrue(NSApp.sendAction(quit.action!, to: quit.target, from: quit))
        XCTAssertEqual(quits, 1)

        let commandQ = try XCTUnwrap(Self.keyDown(characters: "q", flags: [.command], keyCode: UInt16(kVK_ANSI_Q)))
        XCTAssertTrue(QuitShortcut.matches(commandQ))
        XCTAssertNil(controller.consumeCommandQ(commandQ))
        XCTAssertEqual(quits, 2)
        let typedQ = try XCTUnwrap(Self.keyDown(characters: "q", flags: [], keyCode: UInt16(kVK_ANSI_Q)))
        let shifted = try XCTUnwrap(Self.keyDown(characters: "Q", flags: [.command, .shift], keyCode: UInt16(kVK_ANSI_Q)))
        XCTAssertFalse(QuitShortcut.matches(typedQ))
        XCTAssertFalse(QuitShortcut.matches(shifted))
        XCTAssertEqual(controller.consumeCommandQ(typedQ)?.keyCode, typedQ.keyCode)
        XCTAssertEqual(controller.consumeCommandQ(shifted)?.keyCode, shifted.keyCode)
        XCTAssertEqual(quits, 2)

        NSApp.sendEvent(commandQ)
        XCTAssertEqual(quits, 3)
    }

    private func flushMain() {
        let flushed = expectation(description: "flush main")
        DispatchQueue.main.async {
            DispatchQueue.main.async { flushed.fulfill() }
        }
        wait(for: [flushed], timeout: 1)
    }

    @MainActor
    private func attachForRender<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.orderFront(nil)
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func expectationClosed() -> XCTestExpectation {
        let closed = expectation(description: "menu closed again")
        DispatchQueue.main.async {
            DispatchQueue.main.async { closed.fulfill() }
        }
        return closed
    }

    private static func keyDown(characters: String, flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private static func mouseEvent(type: NSEvent.EventType, location: NSPoint, flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    func testStatusMenuPauseTitleIncludesTheShortcutWhenSet() {
        XCTAssertEqual(StatusMenuText.pauseItem(isPaused: false, hotkeyDisplay: ""), L10n.text("暂停记录", "Pause"))
        XCTAssertEqual(StatusMenuText.pauseItem(isPaused: true, hotkeyDisplay: ""), L10n.text("恢复记录", "Resume"))
        XCTAssertEqual(
            StatusMenuText.pauseItem(isPaused: false, hotkeyDisplay: "⌘⇧P"),
            L10n.text("暂停记录", "Pause") + "  ⌘⇧P"
        )
        XCTAssertEqual(
            StatusMenuText.pauseItem(isPaused: true, hotkeyDisplay: "⌘⇧P"),
            L10n.text("恢复记录", "Resume") + "  ⌘⇧P"
        )
        XCTAssertEqual(
            StatusMenuText.pauseItem(isPaused: false, hotkeyDisplay: "⌘⇧P", available: false),
            L10n.text("暂停记录", "Pause")
        )
        XCTAssertEqual(
            StatusMenuText.pauseItem(isPaused: true, hotkeyDisplay: "⌘⇧P", available: false),
            L10n.text("恢复记录", "Resume")
        )
    }

    @MainActor
    func testTogglePauseUsesEachDurationAndRedrawsAfterTheFinalState() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let settings = harness.model.settings
        var redraws = 0
        settings.onPauseStateChange = { redraws += 1 }
        settings.pauseChoice = .manual
        harness.model.togglePause()
        XCTAssertTrue(settings.manuallyPaused)
        XCTAssertTrue(settings.isPaused)
        XCTAssertEqual(redraws, 1)
        harness.model.togglePause()
        XCTAssertFalse(settings.isPaused)
        XCTAssertEqual(redraws, 2)

        settings.pauseChoice = .quarterHour
        let quarterStart = Date()
        harness.model.togglePause()
        let quarter = try XCTUnwrap(settings.pauseUntil)
        XCTAssertEqual(quarter.timeIntervalSince(quarterStart), 15 * 60, accuracy: 5)
        XCTAssertFalse(settings.manuallyPaused)
        harness.model.togglePause()
        XCTAssertFalse(settings.isPaused)

        settings.pauseChoice = .oneHour
        let hourStart = Date()
        harness.model.togglePause()
        let hour = try XCTUnwrap(settings.pauseUntil)
        XCTAssertEqual(hour.timeIntervalSince(hourStart), 60 * 60, accuracy: 5)
        settings.pauseUntil = Date().addingTimeInterval(120)
        harness.model.togglePause()
        XCTAssertNil(settings.pauseUntil)
        XCTAssertFalse(settings.isPaused)

        settings.pauseChoice = .manual
        settings.pauseUntil = Date().addingTimeInterval(-1)
        let redrawsBeforeExpiredToggle = redraws
        harness.model.togglePause()
        XCTAssertTrue(settings.manuallyPaused)
        XCTAssertNil(settings.pauseUntil)
        XCTAssertEqual(redraws, redrawsBeforeExpiredToggle + 1)
    }

    @MainActor
    func testApplyHotkeyCoversSkipConflictFailureAndBothCallbacks() throws {
        let harness = try deleteHarness()
        defer { harness.cleanup() }
        let model = harness.model
        let fake = FakeGlobalHotkeys()
        model.hotkeys = fake
        model.applyHotkey()
        XCTAssertEqual(fake.registrations.map(\.id), [.panel])
        XCTAssertEqual(fake.unregistered, [.pause])
        XCTAssertFalse(model.settings.hotkeyConflict)
        XCTAssertFalse(model.settings.pauseHotkeyConflict)

        model.settings.pauseHotkeyCode = model.settings.hotkeyCode
        model.settings.pauseHotkeyModifiers = model.settings.hotkeyModifiers
        model.settings.pauseHotkeyDisplay = model.settings.hotkeyDisplay
        fake.unregistered.removeAll()
        model.applyHotkey()
        XCTAssertTrue(model.settings.pauseHotkeyConflict)
        XCTAssertEqual(fake.registrations.map(\.id), [.panel])
        XCTAssertEqual(fake.unregistered, [.pause])

        model.settings.pauseHotkeyCode = 35
        model.settings.pauseHotkeyModifiers = 768
        model.settings.pauseHotkeyDisplay = "⌘⇧P"
        fake.fail = [.pause]
        model.applyHotkey()
        XCTAssertTrue(model.settings.pauseHotkeyConflict)
        XCTAssertFalse(fake.registrations.contains(where: { $0.id == .pause }))

        fake.fail = [.panel]
        model.applyHotkey()
        XCTAssertTrue(model.settings.hotkeyConflict)
        XCTAssertFalse(model.settings.pauseHotkeyConflict)
        let pause = try XCTUnwrap(fake.registrations.first(where: { $0.id == .pause }))
        XCTAssertEqual(pause.keyCode, 35)
        XCTAssertEqual(pause.modifiers, 768)

        fake.fail = []
        model.applyHotkey()
        var opened = false
        model.onHotkey = { opened = true }
        fake.registrations.first(where: { $0.id == .panel })?.onPressed()
        XCTAssertFalse(opened)
        let panelTurn = expectation(description: "panel hotkey")
        DispatchQueue.main.async { panelTurn.fulfill() }
        wait(for: [panelTurn], timeout: 1)
        XCTAssertTrue(opened)

        model.settings.manuallyPaused = false
        model.settings.pauseUntil = nil
        let registeredPause = try XCTUnwrap(fake.registrations.first(where: { $0.id == .pause }))
        registeredPause.onPressed()
        let pauseTurn = expectation(description: "pause hotkey")
        DispatchQueue.main.async { pauseTurn.fulfill() }
        wait(for: [pauseTurn], timeout: 1)
        XCTAssertTrue(model.settings.manuallyPaused)

        model.clearPauseHotkey()
        XCTAssertFalse(model.settings.pauseHotkeyIsSet)
        XCTAssertEqual(model.settings.pauseHotkeyCode, 0)
        XCTAssertEqual(model.settings.pauseHotkeyModifiers, 0)
        XCTAssertFalse(model.settings.pauseHotkeyConflict)
        XCTAssertFalse(fake.registrations.contains(where: { $0.id == .pause }))
    }

    @MainActor
    func testKeyRecorderCoversReservedDuplicateAndSavedChords() throws {
        let suite = "recorder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        var recording: HotkeyRecording?
        var message: String?
        var saves = 0
        let coordinator = KeyRecorder(
            recording: Binding(get: { recording }, set: { recording = $0 }),
            message: Binding(get: { message }, set: { message = $0 }),
            settings: settings,
            onSave: { saves += 1 }
        ).makeCoordinator()
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_P)
        ))
        XCTAssertFalse(coordinator.handle(keyCode: UInt16(kVK_ANSI_P), flags: [.command, .shift], characters: "p"))
        XCTAssertEqual(KeyRecorder.Coordinator.forward(nil, event: event)?.keyCode, event.keyCode)
        XCTAssertEqual(coordinator.receive(event)?.keyCode, event.keyCode)
        XCTAssertEqual(KeyRecorder.Coordinator.forward(coordinator, event: event)?.keyCode, event.keyCode)
        let mouse = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
        XCTAssertEqual(coordinator.receive(mouse)?.type, mouse.type)

        recording = .pause
        XCTAssertFalse(coordinator.handle(keyCode: UInt16(kVK_ANSI_P), flags: .shift, characters: "p"))
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(coordinator.handle(keyCode: UInt16(kVK_ANSI_C), flags: .command, characters: "c"))
        XCTAssertEqual(message, L10n.text("不能使用 ⌘C / ⌘V / ⌘X / ⌘Q", "⌘C / ⌘V / ⌘X / ⌘Q are reserved"))
        XCTAssertEqual(recording, .pause)
        XCTAssertEqual(saves, 0)

        XCTAssertTrue(coordinator.handle(keyCode: UInt16(settings.hotkeyCode), flags: modifierFlags(forCarbon: settings.hotkeyModifiers), characters: "v"))
        XCTAssertEqual(message, L10n.text("不能和另一组快捷键相同", "This shortcut is already used"))
        XCTAssertEqual(saves, 0)

        XCTAssertTrue(coordinator.handle(keyCode: UInt16(kVK_ANSI_B), flags: .control, characters: "b"))
        XCTAssertEqual(saves, 1)
        XCTAssertNil(recording)
        recording = .pause
        XCTAssertTrue(coordinator.handle(keyCode: UInt16(kVK_ANSI_K), flags: .option, characters: ""))
        XCTAssertEqual(saves, 2)
        XCTAssertNil(recording)
        XCTAssertNil(message)
        XCTAssertTrue(settings.pauseHotkeyIsSet)
        XCTAssertEqual(settings.pauseHotkeyCode, Int(kVK_ANSI_K))
        XCTAssertTrue(settings.pauseHotkeyDisplay.contains("K"))

        recording = .panel
        XCTAssertTrue(coordinator.handle(keyCode: UInt16(kVK_ANSI_K), flags: .option, characters: "k"))
        XCTAssertEqual(message, L10n.text("不能和另一组快捷键相同", "This shortcut is already used"))
        XCTAssertEqual(saves, 2)
        settings.pauseHotkeyCode = Int(kVK_ANSI_J)
        XCTAssertTrue(coordinator.handle(keyCode: UInt16(kVK_ANSI_L), flags: [.command, .shift], characters: "l"))
        XCTAssertEqual(saves, 3)
        XCTAssertNil(recording)
        XCTAssertEqual(settings.hotkeyCode, Int(kVK_ANSI_L))
        XCTAssertTrue(settings.hotkeyDisplay.contains("L"))

        recording = .panel
        settings.pauseHotkeyModifiers = settings.hotkeyModifiers + 1
        XCTAssertTrue(coordinator.handle(keyCode: UInt16(settings.pauseHotkeyCode), flags: modifierFlags(forCarbon: settings.hotkeyModifiers), characters: "j"))
        XCTAssertEqual(saves, 4)

        coordinator.install()
        coordinator.install()
        coordinator.uninstall()
        coordinator.uninstall()
    }

    @MainActor
    func testPauseSettingViewsRenderRecordingAndPausedStates() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pause-views-\(UUID().uuidString)")!)
        _ = RecordingStatusLabel(settings: settings).body
        settings.manuallyPaused = true
        _ = RecordingStatusLabel(settings: settings).body
        var recording: HotkeyRecording?
        let binding = Binding(get: { recording }, set: { recording = $0 })
        _ = PauseHotkeySetting(settings: settings, recording: binding, onClear: {}).body
        settings.pauseHotkeyDisplay = "⌘⇧P"
        settings.pauseHotkeyConflict = true
        recording = .pause
        _ = PauseHotkeySetting(settings: settings, recording: binding, onClear: {}).body
    }

    func testHotkeyCenterKeepsTheOtherChordWhenOneRegistrationFails() {
        let backend = RecordingHotkeyBackend()
        let center = HotkeyCenter(backend: backend)
        backend.failInstall = true
        XCTAssertFalse(center.register(id: .panel, keyCode: 1, modifiers: 1) {})
        XCTAssertEqual(backend.installCount, 1)
        XCTAssertEqual(backend.removeCount, 0)

        backend.failInstall = false
        backend.failRegisterIDs = [HotkeyCenter.ID.panel.rawValue]
        XCTAssertFalse(center.register(id: .panel, keyCode: 1, modifiers: 1) {})
        XCTAssertEqual(backend.removeCount, 1)
        XCTAssertEqual(backend.installCount, 2)

        backend.failRegisterIDs = []
        var panelHits = 0
        XCTAssertTrue(center.register(id: .panel, keyCode: 9, modifiers: 768) { panelHits += 1 })
        backend.failRegisterIDs = [HotkeyCenter.ID.pause.rawValue]
        XCTAssertFalse(center.register(id: .pause, keyCode: 35, modifiers: 768) {})
        XCTAssertEqual(backend.removeCount, 1)
        XCTAssertEqual(backend.registered[HotkeyCenter.ID.panel.rawValue]?.0, 9)

        center.unregister(id: .pause)
        XCTAssertEqual(backend.removeCount, 1)
        center.fire(id: HotkeyCenter.ID.panel.rawValue)
        center.unregister(id: .panel)
        let captured = expectation(description: "captured callback still runs")
        DispatchQueue.main.async { captured.fulfill() }
        wait(for: [captured], timeout: 1)
        XCTAssertEqual(panelHits, 1)
        XCTAssertEqual(backend.removeCount, 2)

        var replacement = 0
        backend.failRegisterIDs = []
        XCTAssertTrue(center.register(id: .pause, keyCode: 35, modifiers: 768) { replacement += 1 })
        backend.failRegisterIDs = [HotkeyCenter.ID.pause.rawValue]
        XCTAssertFalse(center.register(id: .pause, keyCode: 37, modifiers: 768) { replacement += 100 })
        XCTAssertEqual(backend.registered[HotkeyCenter.ID.pause.rawValue]?.0, 35)
        center.fire(id: HotkeyCenter.ID.pause.rawValue)
        let kept = expectation(description: "failed replacement keeps the previous callback")
        DispatchQueue.main.async { kept.fulfill() }
        wait(for: [kept], timeout: 1)
        XCTAssertEqual(replacement, 1)

        backend.failRegisterIDs = []
        XCTAssertTrue(center.register(id: .pause, keyCode: 36, modifiers: 768) { replacement += 10 })
        center.fire(id: HotkeyCenter.ID.pause.rawValue)
        center.fire(id: 99)
        let replaced = expectation(description: "replacement callback")
        DispatchQueue.main.async { replaced.fulfill() }
        wait(for: [replaced], timeout: 1)
        XCTAssertEqual(replacement, 11)
        XCTAssertEqual(backend.installCount, 4)
        XCTAssertEqual(backend.removeCount, 2)
    }

    func testHotkeyEventDeliversOnlyAParsedIdentifier() throws {
        let backend = RecordingHotkeyBackend()
        let center = HotkeyCenter(backend: backend)
        var hits: [UInt32] = []
        XCTAssertTrue(center.register(id: .pause, keyCode: 35, modifiers: 768) {
            hits.append(HotkeyCenter.ID.pause.rawValue)
        })
        let pointer = Unmanaged.passUnretained(center).toOpaque()
        XCTAssertEqual(center.accept(event: nil), noErr)
        let bare = try XCTUnwrap(makeHotKeyEvent(id: nil))
        defer { ReleaseEvent(bare) }
        XCTAssertEqual(hotkeyCallback(nil, bare, nil), noErr)
        XCTAssertEqual(HotkeyEvents.deliver(event: bare, userData: pointer), noErr)
        let wrongKind = try XCTUnwrap(makeKeyDownEvent())
        defer { ReleaseEvent(wrongKind) }
        XCTAssertEqual(center.accept(event: wrongKind), noErr)
        let parsed = try XCTUnwrap(makeHotKeyEvent(id: HotkeyCenter.ID.pause.rawValue))
        defer { ReleaseEvent(parsed) }
        XCTAssertEqual(hotkeyCallback(nil, parsed, pointer), noErr)
        let turn = expectation(description: "parsed hotkey")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 1)
        XCTAssertEqual(hits, [HotkeyCenter.ID.pause.rawValue])
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

    private func modifierFlags(forCarbon carbon: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & Int(cmdKey) != 0 { flags.insert(.command) }
        if carbon & Int(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & Int(optionKey) != 0 { flags.insert(.option) }
        if carbon & Int(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    private func makeHotKeyEvent(id: UInt32?) -> EventRef? {
        var event: EventRef?
        let created = CreateEvent(
            nil,
            UInt32(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            0,
            EventAttributes(kEventAttributeNone),
            &event
        )
        guard created == noErr, let event else { return nil }
        guard let id else { return event }
        var hotKeyID = EventHotKeyID(signature: fourChar("CLAP"), id: id)
        let set = withUnsafeBytes(of: hotKeyID) { buffer -> OSStatus in
            guard let bytes = buffer.baseAddress else { return OSStatus(paramErr) }
            return SetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                buffer.count,
                bytes
            )
        }
        guard set == noErr else {
            ReleaseEvent(event)
            return nil
        }
        return event
    }

    private func makeKeyDownEvent() -> EventRef? {
        var event: EventRef?
        let created = CreateEvent(
            nil,
            UInt32(kEventClassKeyboard),
            UInt32(kEventRawKeyDown),
            0,
            EventAttributes(kEventAttributeNone),
            &event
        )
        guard created == noErr else { return nil }
        return event
    }

    private struct DeleteHarness {
        let model: AppModel
        let directory: URL
        let suite: String

        @MainActor
        func insert(_ text: String) throws -> ClipboardItem {
            let captured = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [
                PasteboardItemData(values: [PasteboardUTI.plain: Data(text.utf8)])
            ])))
            return try model.store.insertOrTouch(captured, sourceBundleID: "com.example", sourceName: "Example")
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    private func deleteHarness() throws -> DeleteHarness {
        let suite = "clipboard-delete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try HistoryStore(directory: directory)
        let model = AppModel(store: store, settings: AppSettings(defaults: defaults))
        return DeleteHarness(model: model, directory: directory, suite: suite)
    }

    private func installClearBlocker(at directory: URL) throws {
        try executeSQL("""
        CREATE TRIGGER block_clear BEFORE DELETE ON items
        BEGIN
          SELECT RAISE(ABORT, 'blocked');
        END;
        """, at: directory)
    }

    private func dropItemsTable(at directory: URL) throws {
        try executeSQL("DROP TABLE items", at: directory)
    }

    private func executeSQL(_ sql: String, at directory: URL) throws {
        var handle: OpaquePointer?
        let path = directory.appendingPathComponent("history.db").path
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw StoreError.open("open")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2_000)
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard code == SQLITE_OK else {
            throw StoreError.sql(message.map { String(cString: $0) } ?? sql)
        }
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

private final class TrackingMenu: NSMenu {
    var points: [NSPoint] = []

    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        points.append(location)
        return true
    }
}

private final class TrackingButton: NSButton {
    var clicks = 0

    override func performClick(_ sender: Any?) {
        clicks += 1
    }
}

private final class FlippedButton: NSButton {
    override var isFlipped: Bool { true }
}

final class FakeGlobalHotkeys: GlobalHotkeys {
    struct Registration {
        var id: HotkeyCenter.ID
        var keyCode: UInt32
        var modifiers: UInt32
        var onPressed: () -> Void
    }

    var registrations: [Registration] = []
    var unregistered: [HotkeyCenter.ID] = []
    var fail: Set<HotkeyCenter.ID> = []

    func register(id: HotkeyCenter.ID, keyCode: UInt32, modifiers: UInt32, onPressed: @escaping () -> Void) -> Bool {
        if fail.contains(id) { return false }
        registrations.removeAll { $0.id == id }
        registrations.append(Registration(id: id, keyCode: keyCode, modifiers: modifiers, onPressed: onPressed))
        return true
    }

    func unregister(id: HotkeyCenter.ID) {
        unregistered.append(id)
        registrations.removeAll { $0.id == id }
    }
}

private final class RecordingHotkeyBackend: HotkeyBackend {
    var installCount = 0
    var removeCount = 0
    var failInstall = false
    var failRegisterIDs: Set<UInt32> = []
    var registered: [UInt32: (UInt32, UInt32)] = [:]

    func installHandler(for center: HotkeyCenter) -> Bool {
        installCount += 1
        return !failInstall
    }

    func removeHandler() {
        removeCount += 1
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        if failRegisterIDs.contains(id) { return false }
        registered[id] = (keyCode, modifiers)
        return true
    }

    func unregister(id: UInt32) {
        registered.removeValue(forKey: id)
    }
}
