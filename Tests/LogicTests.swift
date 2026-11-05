import AppKit
import Carbon
import SQLite3
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
        XCTAssertNil(String(data: badUTF16, encoding: .utf16))
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
            pixels[index] = UInt8((index * 37) % 251)
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

    func testPauseHotkeyStartsUnsetAndRejectsThePanelChord() {
        XCTAssertEqual(
            HotkeyPlan.pause(code: 0, modifiers: 0, display: "", panelCode: 9, panelModifiers: 768),
            .skip
        )
        XCTAssertEqual(
            HotkeyPlan.pause(code: 9, modifiers: 768, display: "⌘⇧V", panelCode: 9, panelModifiers: 768),
            .conflict
        )
        XCTAssertEqual(
            HotkeyPlan.pause(code: 35, modifiers: 768, display: "⌘⇧P", panelCode: 9, panelModifiers: 768),
            .register(keyCode: 35, modifiers: 768)
        )
    }

    func testPauseHotkeyDefaultsToUnset() {
        let suite = "pause-hotkey-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.pauseHotkeyIsSet)
        XCTAssertEqual(settings.pauseHotkeyDisplay, "")
        XCTAssertEqual(settings.pauseHotkeyCode, 0)
        XCTAssertEqual(settings.hotkeyDisplay, "⌘⇧V")
        XCTAssertFalse(settings.isPaused)
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
