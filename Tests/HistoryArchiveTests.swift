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

extension HistoryArchiveTests {
    func testArchiveAggregateAndEncodedSizeLimits() throws {
        let image = ArchiveRepresentation(uti: "public.png", data: Data(repeating: 0, count: 10485760), inlineValue: nil)
        let record = ArchiveRecord(kind: .image, plainText: "", sourceBundleID: nil, sourceName: "Demo", createdAt: Date(timeIntervalSince1970: 100), lastUsedAt: Date(timeIntervalSince1970: 100), pinned: false, label: nil, byteSize: 10485760, imageWidth: 100, imageHeight: 100, payloadOversize: false, representations: [image])
        XCTAssertThrowsError(try HistoryArchive(items: Array(repeating: record, count: 7)).validate())
        XCTAssertThrowsError(try HistoryArchive(items: Array(repeating: record, count: 5)).encoded())
    }
}

#if canImport(AppKit) && !TRANSFER_CORE_TESTS
import AppKit
import SwiftUI

extension HistoryArchiveTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func textRecord(_ text: String = "hello", pinned: Bool = false, date: Date = Date()) -> ArchiveRecord {
        ArchiveRecord(kind: .text, plainText: text, sourceBundleID: "demo", sourceName: "Demo", createdAt: Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)), lastUsedAt: Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)),
            pinned: pinned, label: "Work", byteSize: text.utf8.count, imageWidth: nil, imageHeight: nil, payloadOversize: false,
            representations: [ArchiveRepresentation(uti: PasteboardUTI.plain, data: Data(text.utf8), inlineValue: nil)])
    }
    private var unlimited: RetentionPolicy { RetentionPolicy(maxCount: nil, maxAge: nil, maxImageBytes: RetentionPolicy.imageCap) }
    private func seed(_ store: HistoryStore, _ text: String) throws -> ClipboardItem {
        try store.insertOrTouch(textRecord(text).captured(), sourceBundleID: "local", sourceName: "Local")
    }
    func testStreamRoundTripAndDuplicateKeysAtEveryLevel() throws {
        let archive = HistoryArchive(items: [textRecord("line\n\"quote\"\\中文")])
        let data = try archive.encoded()
        XCTAssertEqual(try ArchiveStream(data: data).read().items, archive.items)
        let root = String(decoding: data, as: UTF8.self)
        for invalid in [
            root.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":1,\"formatVersion\":1"),
            root.replacingOccurrences(of: "\"plainText\":", with: "\"plainText\":\"duplicate\",\"plainText\":"),
            root.replacingOccurrences(of: "\"uti\":", with: "\"uti\":\"bad\",\"uti\":"),
            root + "x", "[]", "{", "{\"items\":false}", "{\"unknown\":1}",
            root.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":01")
        ] { XCTAssertThrowsError(try HistoryArchive.decode(Data(invalid.utf8))) }
        let cancelled = ArchiveStream(data: data); cancelled.cancelled = { true }
        XCTAssertThrowsError(try cancelled.read())
        let directory = try temporary(), file = directory.appendingPathComponent("archive.json")
        try data.write(to: file)
        XCTAssertEqual(try ArchiveStream.read(file).items, archive.items)
        try FileHandle(forWritingTo: file).truncate(atOffset: UInt64(HistoryArchive.maxBytes) + 1)
        XCTAssertThrowsError(try ArchiveStream.read(file))
    }
    func testPreviewImportDeduplicationAndLocalMetadataPreserved() throws {
        let store = try HistoryStore(directory: temporary())
        let local = try seed(store, "local")
        try store.setPinned(id: local.id, pinned: true)
        var old = textRecord("local"); old.sourceName = "External"; old.label = "External"
        let fresh = textRecord("new", pinned: true)
        let plan = try store.previewImport(HistoryArchive(items: [old, fresh, fresh]), policy: unlimited)
        XCTAssertEqual(plan.total, 3); XCTAssertEqual(plan.fileDuplicates, 1); XCTAssertEqual(plan.localDuplicates, 1)
        XCTAssertEqual(plan.retained, 1); XCTAssertEqual(plan.netChange, 1)
        XCTAssertEqual(try store.commitImport(plan, policy: unlimited, allowExistingEviction: false), 1)
        let items = try store.fetchAll()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.id, local.id)
        XCTAssertEqual(items.first?.sourceName, "Local")
        XCTAssertNil(items.first?.label)
        XCTAssertEqual(items.last?.label, "Work")
        let again = try store.previewImport(HistoryArchive(items: [old, fresh]), policy: unlimited)
        XCTAssertEqual(again.localDuplicates, 2)
        XCTAssertEqual(try store.commitImport(again, policy: unlimited, allowExistingEviction: false), 0)
    }
    func testRetentionConfirmationAndStalePlans() throws {
        let store = try HistoryStore(directory: temporary())
        _ = try seed(store, "old")
        let policy = RetentionPolicy(maxCount: 1, maxAge: nil, maxImageBytes: RetentionPolicy.imageCap)
        let archive = HistoryArchive(items: [textRecord("fresh", date: Date().addingTimeInterval(1))])
        let plan = try store.previewImport(archive, policy: policy)
        XCTAssertEqual(plan.existingEvicted, 1)
        XCTAssertThrowsError(try store.commitImport(plan, policy: policy, allowExistingEviction: false))
        XCTAssertThrowsError(try store.commitImport(plan, policy: unlimited, allowExistingEviction: true))
        try store.invalidateImportPlans()
        XCTAssertThrowsError(try store.commitImport(plan, policy: policy, allowExistingEviction: true))
        let updated = try store.previewImport(archive, policy: policy)
        XCTAssertEqual(try store.commitImport(updated, policy: policy, allowExistingEviction: true), 1)
        XCTAssertEqual(try store.fetchAll().map(\.plainText), ["fresh"])
        let ancient = textRecord("ancient", date: Date(timeIntervalSince1970: 1))
        let agePolicy = RetentionPolicy(maxCount: nil, maxAge: 1000, maxImageBytes: RetentionPolicy.imageCap)
        let expiry = try store.previewImport(HistoryArchive(items: [ancient]), policy: agePolicy)
        XCTAssertEqual(expiry.newEvicted, 1)
        XCTAssertEqual(try store.commitImport(expiry, policy: agePolicy, allowExistingEviction: true), 0)
    }
    func testEveryPrecommitFailureRollsBackMetadataAndPayloads() throws {
        for phase in ["payload-written", "payload-moved", "before-commit"] {
            let directory = try temporary(), store = try HistoryStore(directory: directory)
            let original = try seed(store, "original")
            let plan = try store.previewImport(HistoryArchive(items: [textRecord("new")]), policy: unlimited)
            XCTAssertThrowsError(try store.commitImport(plan, policy: unlimited, allowExistingEviction: false) { point in
                if point == phase { throw CocoaError(.fileWriteOutOfSpace) }
            })
            XCTAssertEqual(try store.fetchAll().map(\.id), [original.id])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("payloads").path).count, 1)
            try store.recoverArchives()
            XCTAssertEqual(try store.fetchAll().count, 1)
        }
    }
    func testDatabaseFailureDuringBatchRollsBackAndPostcommitCleanupDoesNotReportFailure() throws {
        let store = try HistoryStore(directory: temporary())
        _ = try seed(store, "original")
        let plan = try store.previewImport(HistoryArchive(items: [textRecord("new")]), policy: unlimited)
        try store.database.execute("CREATE TRIGGER reject_archive BEFORE INSERT ON items BEGIN SELECT RAISE(ABORT,'injected'); END")
        XCTAssertThrowsError(try store.commitImport(plan, policy: unlimited, allowExistingEviction: false))
        XCTAssertEqual(try store.count(), 1)
        try store.database.execute("DROP TRIGGER reject_archive")
        let retry = try store.previewImport(HistoryArchive(items: [textRecord("new")]), policy: unlimited)
        XCTAssertEqual(try store.commitImport(retry, policy: unlimited, allowExistingEviction: false) { point in
            if point == "after-commit" { throw CocoaError(.fileWriteUnknown) }
        }, 1)
        XCTAssertEqual(try store.count(), 2)
    }
    func testExportLeaseSurvivesClearAndAtomicCancellationPreservesDestination() throws {
        let directory = try temporary(), store = try HistoryStore(directory: directory)
        let item = try seed(store, "keep payload")
        var snapshot: ArchiveSnapshot? = try store.archiveSnapshot()
        var second: ArchiveSnapshot? = try store.archiveSnapshot(ids: [item.id])
        XCTAssertEqual(store.payloadLeases[item.id], 2)
        try store.clearAll()
        XCTAssertTrue(try store.fetchAll().isEmpty)
        XCTAssertEqual(try snapshot!.record(at: 0).plainText, "keep payload")
        second = nil
        XCTAssertEqual(store.payloadLeases[item.id], 1)
        let file = directory.appendingPathComponent("backup.json")
        try Data("original".utf8).write(to: file)
        XCTAssertThrowsError(try snapshot!.write(to: file, plainText: false, cancelled: { true }))
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
        try snapshot!.write(to: file, plainText: false)
        XCTAssertEqual(try ArchiveStream.read(file).items.first?.plainText, "keep payload")
        let txt = directory.appendingPathComponent("backup.txt")
        try snapshot!.write(to: txt, plainText: true)
        XCTAssertTrue(try String(contentsOf: txt).contains("keep payload"))
        let invalid = directory.appendingPathComponent("missing/out.json")
        XCTAssertThrowsError(try snapshot!.write(to: invalid, plainText: false))
        snapshot = nil
        XCTAssertNil(store.payloadLeases[item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("payloads/" + item.id).path))
        _ = second
    }
    func testMissingPayloadNeverExportsAsSuccess() throws {
        let directory = try temporary(), store = try HistoryStore(directory: directory)
        let item = try seed(store, "hello")
        let snapshot = try store.archiveSnapshot()
        store.payloads.removeItem(id: item.id)
        XCTAssertThrowsError(try snapshot.record(at: 0))
        XCTAssertThrowsError(try snapshot.write(to: directory.appendingPathComponent("out.json"), plainText: false))
        let empty = try store.archiveSnapshot(ids: [])
        XCTAssertThrowsError(try empty.write(to: directory.appendingPathComponent("empty.json"), plainText: false))
    }
    func testStartupRecoversOrphansAndCommittedReferences() throws {
        let directory = try temporary()
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let item = try seed(store!, "keep")
        let orphan = UUID().uuidString, job = UUID().uuidString
        _ = try store!.payloads.write(itemID: orphan, uti: PasteboardUTI.plain, data: Data("orphan".utf8))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("staging/" + job), withIntermediateDirectories: true)
        try store!.database.run("INSERT INTO archive_jobs VALUES (?,0)") { bindText($0,1,job) }
        try store!.database.run("INSERT INTO archive_cleanup VALUES (?)") { bindText($0,1,item.id) }
        store = nil
        let recovered = try HistoryStore(directory: directory)
        XCTAssertEqual(try recovered.fetchAll().first?.id, item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("payloads/" + orphan).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("staging/" + job).path))
        XCTAssertNotNil(try recovered.loadRepresentations(for: item.id).first?.data)
    }
    func testPreviewIdentitiesAndInvalidFileReferences() throws {
        var preview = textRecord("preview"); preview.payloadOversize = true; preview.representations = []; preview.byteSize = 2_000_000
        let first = try preview.captured()
        XCTAssertTrue(first.contentHash.hasPrefix("archive-preview-v1:"))
        var changed = preview; changed.byteSize += 1
        XCTAssertNotEqual(try changed.captured().contentHash, first.contentHash)
        let store = try HistoryStore(directory: temporary())
        _ = try seed(store, "preview")
        let plan = try store.previewImport(HistoryArchive(items: [preview, preview]), policy: unlimited)
        XCTAssertEqual(plan.fileDuplicates, 1); XCTAssertEqual(plan.localDuplicates, 0)
        XCTAssertEqual(try store.commitImport(plan, policy: unlimited, allowExistingEviction: false), 1)
        var bad = textRecord(); bad.representations[0].data = nil; bad.representations[0].inlineValue = "hello"
        XCTAssertThrowsError(try bad.captured())
        bad = textRecord(); bad.plainText = "forged"
        XCTAssertThrowsError(try bad.captured())
        bad = textRecord(); bad.files = [FileFingerprint(path: "/tmp/../escape", size: 0, modifiedAt: 0)]
        XCTAssertThrowsError(try bad.captured())
    }
    func testFileReferenceRoundTripNeverStatsReferencedFiles() throws {
        let file = FileFingerprint(path: "/does-not-exist/hello.txt", size: 123, modifiedAt: 456)
        let record = ArchiveRecord(files: [file], kind: .file, plainText: "hello.txt", sourceBundleID: nil, sourceName: "Demo", createdAt: Date(), lastUsedAt: Date(), pinned: false,
            label: nil, byteSize: 123, imageWidth: nil, imageHeight: nil, payloadOversize: false,
            representations: [ArchiveRepresentation(uti: PasteboardUTI.fileURL, data: nil, inlineValue: file.path)])
        XCTAssertEqual(try record.captured().contentHash, ContentHash.files([file]))
        let store = try HistoryStore(directory: temporary())
        let plan = try store.previewImport(HistoryArchive(items: [record]), policy: unlimited)
        XCTAssertEqual(try store.commitImport(plan, policy: unlimited, allowExistingEviction: false), 1)
        XCTAssertEqual(try store.archiveSnapshot().record(at: 0).files, [file])
    }
}
#endif

#if canImport(AppKit) && !TRANSFER_CORE_TESTS
extension HistoryArchiveTests {
    @MainActor
    private func awaitTransfer(_ model: HistoryTransferModel, phase: HistoryTransferModel.Phase) async throws {
        for _ in 0..<300 where model.phase != phase { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.phase, phase)
    }
    @MainActor
    func testTransferModelImportExportCancelAndResultFlows() async throws {
        let directory = try temporary(), store = try HistoryStore(directory: directory)
        let model = HistoryTransferModel(store: store, policy: { self.unlimited })
        model.commit(); model.refreshPreview()
        XCTAssertFalse(model.canCommit); XCTAssertFalse(model.isBusy)
        model.selectImportFile = { nil }; model.chooseImport(source: "settings")
        XCTAssertFalse(model.presented)
        model.openExport(ids: [], source: "history"); XCTAssertEqual(model.exportCount, 0)
        model.chooseExport(); model.export(to: directory.appendingPathComponent("empty.json"))
        XCTAssertEqual(model.phase, .result)
        model.close(); XCTAssertFalse(model.presented)
        let archive = HistoryArchive(items: [textRecord("imported")]), file = directory.appendingPathComponent("input.json")
        try archive.encoded().write(to: file)
        model.selectImportFile = { file }; model.chooseImport(source: "settings")
        XCTAssertTrue(model.isBusy)
        try await awaitTransfer(model, phase: .preview)
        XCTAssertTrue(model.canCommit)
        var changed = false; model.onChange = { changed = true }
        model.commit(); model.close()
        XCTAssertTrue(model.presented)
        try await awaitTransfer(model, phase: .result)
        XCTAssertTrue(changed); XCTAssertEqual(try store.count(), 1)
        XCTAssertNotNil(model.message)
        try model.prepare(archive); XCTAssertFalse(model.canCommit)
        model.openExport(ids: Set(try store.fetchAll().map(\.id)), source: "history")
        XCTAssertEqual(model.exportCount, 1)
        XCTAssertGreaterThan(model.exportEstimatedBytes,0)
        model.selectExportFile = { _ in nil }; model.chooseExport()
        XCTAssertEqual(model.phase, .export)
        let output = directory.appendingPathComponent("output.json")
        model.selectExportFile = { _ in output }; model.chooseExport()
        try await awaitTransfer(model, phase: .result)
        XCTAssertEqual(try ArchiveStream.read(output).items.first?.plainText, "imported")
        model.openExport(ids: nil, source: "settings"); model.plainText = true
        let txt = directory.appendingPathComponent("output.txt")
        model.export(to: txt); try await awaitTransfer(model, phase: .result)
        XCTAssertTrue(try String(contentsOf: txt).contains("imported"))
        model.openExport(ids: nil, source: "settings")
        model.export(to: directory.appendingPathComponent("missing/out.json")); try await awaitTransfer(model, phase: .result)
        model.load(directory.appendingPathComponent("missing.json"), source: "history"); try await awaitTransfer(model, phase: .result)
        model.load(file, source: "history"); model.close()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(model.presented); XCTAssertNil(model.plan)
        model.openExport(ids: nil, source: "settings"); model.export(to: directory.appendingPathComponent("cancelled.json")); model.close()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(model.presented)
    }
    @MainActor
    func testTransferModelStalePreviewAndDatabaseFailure() async throws {
        let store = try HistoryStore(directory: temporary())
        var policy = self.unlimited
        let model = HistoryTransferModel(store: store, policy: { policy })
        let archive = HistoryArchive(items: [textRecord("fresh")])
        try model.prepare(archive)
        try store.invalidateImportPlans()
        model.commit(); try await awaitTransfer(model, phase: .preview)
        XCTAssertNotNil(model.message); XCTAssertFalse(model.allowEviction)
        policy.maxCount = 1
        try model.prepare(archive)
        try store.database.execute("CREATE TRIGGER fail_import BEFORE INSERT ON items BEGIN SELECT RAISE(ABORT,'injected'); END")
        model.commit(); try await awaitTransfer(model, phase: .result)
        XCTAssertEqual(try store.count(), 0)
        try store.database.execute("DROP TRIGGER fail_import")
        for error in [ArchiveError.limitExceeded, .missingPayload, .invalidRecord, .invalidFormat] { model.fail(error); XCTAssertNotNil(model.message) }
        model.fail(CancellationError()); XCTAssertNotNil(model.message)
        model.fail(CocoaError(.fileWriteOutOfSpace)); XCTAssertNotNil(model.message)
        try store.database.execute("DROP TABLE items")
        model.refreshPreview(); XCTAssertEqual(model.phase, .result)
        XCTAssertEqual(model.exportCount, 0)
        XCTAssertEqual(model.exportEstimatedBytes,0)
    }
    @MainActor
    func testTransferDialogsCancellationAndRenderAllStates() throws {
        let store = try HistoryStore(directory: temporary())
        let model = HistoryTransferModel(store: store, policy: { self.unlimited })
        _ = try seed(store, "old")
        XCTAssertGreaterThan(model.exportEstimatedBytes,0)
        DispatchQueue.main.async { NSApp.abortModal() }
        model.chooseImport(source: "settings")
        model.openExport(ids: nil, source: "settings")
        DispatchQueue.main.async { NSApp.abortModal() }
        model.chooseExport()
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:420,height:480),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryTransferView(model: model))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let policy = RetentionPolicy(maxCount: 1, maxAge: nil, maxImageBytes: RetentionPolicy.imageCap)
        let constrained = HistoryTransferModel(store: store, policy: { policy })
        try constrained.prepare(HistoryArchive(items: [textRecord("new", date: Date().addingTimeInterval(1))]))
        window.contentView = NSHostingView(rootView: HistoryTransferView(model: constrained))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        constrained.allowEviction = true
        constrained.phase = .committing
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        constrained.phase = .validating
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        constrained.fail(ArchiveError.invalidRecord)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.close()
    }
    func testImagePayloadValidationAndRoundTrip() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:8,bitsPerPixel:32)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let captured = CaptureBuilder.build(PasteboardSnapshot(items:[PasteboardItemData(values:[PasteboardUTI.png:data])]))!
        let record = ArchiveRecord(kind:.image,plainText:captured.plainText,sourceBundleID:nil,sourceName:"Demo",createdAt:Date(),lastUsedAt:Date(),pinned:false,label:nil,byteSize:data.count,imageWidth:2,imageHeight:2,payloadOversize:false,representations:[ArchiveRepresentation(uti:PasteboardUTI.png,data:data,inlineValue:nil)])
        XCTAssertEqual(try record.captured().contentHash, captured.contentHash)
        let store = try HistoryStore(directory:temporary())
        let plan = try store.previewImport(HistoryArchive(items:[record]),policy:unlimited)
        XCTAssertEqual(try store.commitImport(plan,policy:unlimited,allowExistingEviction:false),1)
        let snapshot = try store.archiveSnapshot()
        let file = store.directory.appendingPathComponent("image.json")
        try snapshot.write(to:file,plainText:false)
        XCTAssertEqual(try ArchiveStream.read(file).items.first?.imageWidth,2)
    }
    func testLegacyFileMetadataAndPreviewExport() throws {
        let store = try HistoryStore(directory:temporary())
        let file = FileFingerprint(path:"/missing/legacy.txt",size:123,modifiedAt:456)
        let captured = CapturedClipboard(kind:.file,plainText:"legacy.txt",contentHash:ContentHash.files([file]),byteSize:123,imageWidth:nil,imageHeight:nil,oversize:false,representations:[CapturedRepresentation(uti:PasteboardUTI.fileURL,data:nil,inlineValue:file.path)])
        _ = try store.insertOrTouch(captured,sourceBundleID:nil,sourceName:"Legacy")
        let snapshot = try store.archiveSnapshot(), record = try snapshot.record(at:0)
        XCTAssertEqual(record.legacyFileMetadata,true)
        XCTAssertNoThrow(try record.captured())
        let duplicate = try store.previewImport(HistoryArchive(items:[record]),policy:unlimited)
        XCTAssertEqual(duplicate.localDuplicates,1)
        let text = store.directory.appendingPathComponent("legacy.txt")
        try snapshot.write(to:text,plainText:true)
        XCTAssertTrue(try String(contentsOf:text).contains(file.path))
        var preview = textRecord("preview"); preview.payloadOversize=true; preview.representations=[]
        let plan = try store.previewImport(HistoryArchive(items:[preview]),policy:unlimited)
        _ = try store.commitImport(plan,policy:unlimited,allowExistingEviction:false)
        let all = try store.archiveSnapshot()
        try all.write(to:store.directory.appendingPathComponent("all.txt"),plainText:true)
    }
}
#endif

#if canImport(AppKit) && !TRANSFER_CORE_TESTS
extension HistoryArchiveTests {
    func testStrictWireFieldsTruncationAndRepresentationValidation() throws {
        for raw in ["{\"format\":\"unfinished", "{\"items\":[", "{\"items\":[{", "{\"items\":[{\"files\":[]}", "{\"items\":[{\"files\":[{}]}]}"] {
            XCTAssertThrowsError(try HistoryArchive.decode(Data(raw.utf8)))
        }
        for raw in ["[]", "{\"payloadPath\":\"/tmp/evil\"}", "{\"representations\":[{\"path\":\"/tmp/evil\"}]}", "{\"files\":[{\"url\":\"https://example.com\"}]}"] {
            XCTAssertThrowsError(try ArchiveWire.validateRecord(Data(raw.utf8)))
        }
        XCTAssertNoThrow(try ArchiveWire.validateRecord(Data("{\"files\":[{\"path\":\"/tmp/file\",\"size\":0,\"modifiedAt\":0}]}".utf8)))
        XCTAssertThrowsError(try ArchiveRepresentation(uti:PasteboardUTI.plain,data:nil,inlineValue:nil).payloadByteCount())
        XCTAssertThrowsError(try ArchiveRepresentation(uti:PasteboardUTI.plain,data:Data(),inlineValue:"").payloadByteCount())
        let reference = FileFingerprint(path:"/missing/file",size:1,modifiedAt:1)
        let record = ArchiveRecord(files:[reference],kind:.file,plainText:"file",sourceBundleID:nil,sourceName:"",createdAt:Date(timeIntervalSince1970:1),lastUsedAt:Date(timeIntervalSince1970:1),pinned:false,label:nil,byteSize:1,imageWidth:nil,imageHeight:nil,payloadOversize:false,representations:[ArchiveRepresentation(uti:PasteboardUTI.fileURL,data:nil,inlineValue:reference.path)])
        let data = try HistoryArchive(items:[record]).encoded()
        XCTAssertEqual(try HistoryArchive.decode(data).items.first?.files,[reference])
        let store = try HistoryStore(directory:temporary())
        let plan = try store.previewImport(HistoryArchive(items:[record]),policy:unlimited)
        _ = try store.commitImport(plan,policy:unlimited,allowExistingEviction:false)
        XCTAssertEqual(try store.previewImport(HistoryArchive(items:[record]),policy:unlimited).localDuplicates,1)
        store.releaseArchive([UUID().uuidString])
        var invalidDate = HistoryArchive(items:[]); invalidDate.exportedAt = Date(timeIntervalSince1970:-1)
        XCTAssertThrowsError(try invalidDate.validate())
    }
}
#endif

#if canImport(AppKit) && !TRANSFER_CORE_TESTS
extension HistoryArchiveTests {
    func testActualProcessCrashesRecoverBeforeAndAfterCommit() throws {
        for phase in ["payload-written", "payload-moved", "before-commit", "after-commit"] {
            let directory = try temporary()
            var original: HistoryStore? = try HistoryStore(directory:directory)
            let keep = try seed(original!,"keep")
            let file = directory.appendingPathComponent("crash-input.json")
            try HistoryArchive(items:[textRecord("imported")]).encoded().write(to:file)
            original = nil
            let process = Process(); process.executableURL = Bundle.main.executableURL
            process.arguments = [ArchiveCrashHarness.argument,directory.path,phase]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,99)
            let recovered = try HistoryStore(directory:directory), items = try recovered.fetchAll()
            XCTAssertTrue(items.contains(where:{$0.id == keep.id}))
            XCTAssertEqual(items.count,phase == "after-commit" ? 2 : 1)
            for item in items { XCTAssertNotNil(try recovered.loadRepresentations(for:item.id).first?.data) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.appendingPathComponent("payloads").path).count,items.count)
        }
        XCTAssertFalse(ArchiveCrashHarness.runIfRequested([]))
        let directory = try temporary()
        var status:Int32 = 0
        XCTAssertTrue(ArchiveCrashHarness.runIfRequested(["app",ArchiveCrashHarness.argument,directory.path,"before-commit"],crash:{status=$0}))
        XCTAssertEqual(status,98)
        try HistoryArchive(items:[textRecord("ok")]).encoded().write(to:directory.appendingPathComponent("crash-input.json"))
        XCTAssertTrue(ArchiveCrashHarness.runIfRequested(["app",ArchiveCrashHarness.argument,directory.path,"before-commit"],crash:{status=$0}))
        XCTAssertEqual(status,99)
    }
}
#endif

#if canImport(AppKit) && !TRANSFER_CORE_TESTS
extension HistoryArchiveTests {

}
#endif

#if canImport(AppKit) && !TRANSFER_CORE_TESTS
extension HistoryArchiveTests {
    func testArchiveDatesPreserveDatabasePrecisionAndRejectMalformedFractions() throws {
        let date = Date(timeIntervalSince1970:1_794_393_123.1234567)
        XCTAssertEqual(ArchiveDates.date(ArchiveDates.string(date)),date)
        XCTAssertEqual(ArchiveDates.date("1970-01-01T00:00:01Z"),Date(timeIntervalSince1970:1))
        for string in [String(repeating:"a",count:65),"invalid","2026-11-11T00:00:00.Z","2026-11-11T00:00:00.1234567890Z","2026-11-11T00:00:00.abcZ"] {
            XCTAssertNil(ArchiveDates.date(string))
        }
        let encoded = Data("\"invalid\"".utf8)
        XCTAssertThrowsError(try ArchiveDates.decoder().decode(Date.self,from:encoded))
        var record = textRecord("fractional");record.createdAt=date;record.lastUsedAt=date
        XCTAssertEqual(try HistoryArchive.decode(HistoryArchive(items:[record]).encoded()).items.first?.createdAt,date)
        record.imageHeight=1
        XCTAssertThrowsError(try HistoryArchive(items:[record]).validate())
        record.imageWidth = -1
        XCTAssertThrowsError(try HistoryArchive(items:[record]).validate())
        record.imageHeight=nil;record.imageWidth=nil;record.label=" Work "
        XCTAssertThrowsError(try HistoryArchive(items:[record]).validate())
    }
}
#endif

#if canImport(AppKit) && !TRANSFER_CORE_TESTS
extension HistoryArchiveTests {
    func testImportCancellationAlsoStopsPostparseValidationAndPlanning() throws {
        let archive=HistoryArchive(items:[textRecord("one"),textRecord("two")])
        XCTAssertThrowsError(try archive.validate(cancelled:{true})) { XCTAssertTrue($0 is CancellationError) }
        let store=try HistoryStore(directory:temporary())
        var checks=0
        XCTAssertThrowsError(try store.previewImport(archive,policy:unlimited,cancelled:{checks += 1;return checks > 2})) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try store.count(),0)
    }
}
#endif

#if canImport(AppKit) && !TRANSFER_CORE_TESTS
extension HistoryArchiveTests {
    func testRemovedRulesStayInactiveAndLegacyLabelsOnlyRoundTripAsMetadata() throws {
        let store = try HistoryStore(directory: temporary())
        // Existing v4 databases may contain active-looking rules. They are never read or executed.
        try store.database.execute("CREATE TABLE capture_rules(id INTEGER PRIMARY KEY,config TEXT); INSERT INTO capture_rules VALUES (1,'invalid legacy rules')")
        let item = try seed(store, "验证码：123456")
        XCTAssertNil(item.label)
        try store.database.run("INSERT INTO item_labels VALUES (?,?)") { bindText($0,1,item.id); bindText($0,2,"LegacyTag") }
        let legacy = try store.fetchAll()[0]
        XCTAssertFalse(HistoryQuery.matches(legacy,query:"LegacyTag",filter:.all))
        let snapshot = try store.archiveSnapshot()
        XCTAssertEqual(try snapshot.record(at:0).label,"LegacyTag")
        let fresh = try seed(store,"fresh history")
        XCTAssertNil(fresh.label)
        XCTAssertFalse(SettingsTab.allCases.map(\.rawValue).contains("rules"))
        let board = NSPasteboard(name:NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("验证码：654321",forType:.string)
        XCTAssertNotNil(CaptureBuilder.build(PasteboardReader.snapshot(board)))
    }
    func testArchiveSchemaRejectsFutureVersionAndPreservesLegacyTables() throws {
        let database = try SQLiteDatabase(path:":memory:")
        try database.execute("CREATE TABLE items(id TEXT PRIMARY KEY); CREATE TABLE representations(item_id TEXT)")
        let schema = ArchiveSchema(database:database,lock:NSLock())
        try schema.migrate()
        try schema.migrate()
        try database.execute("PRAGMA user_version=5")
        XCTAssertThrowsError(try schema.migrate())
        var version:Int64 = 0
        try database.query("PRAGMA user_version") { version=database.int64($0,0) }
        XCTAssertEqual(version,5)
    }
    @MainActor
    func testRemovedRulesSettingsAndLabelFreeHistoryRender() throws {
        let store = try HistoryStore(directory: temporary())
        let settings = AppSettings(defaults:UserDefaults(suiteName:UUID().uuidString)!)
        let model = AppModel(store:store,settings:settings)
        let item = try seed(store,"visible")
        try store.database.run("INSERT INTO item_labels VALUES (?,?)") { bindText($0,1,item.id);bindText($0,2,"Hidden legacy label") }
        model.reload()
        XCTAssertEqual(model.visibleItems().count,1)
        model.query="Hidden legacy label";XCTAssertTrue(model.visibleItems().isEmpty)
        model.query=""
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:420,height:480),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:HistoryPanelView().environmentObject(model))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        window.close()
    }
}
#endif

#if canImport(AppKit) && !TRANSFER_CORE_TESTS
extension HistoryArchiveTests {
    @MainActor
    func testArchiveMultipleRecordsAndFailureLocationsRemainSupported() throws {
        let archive=HistoryArchive(items:[textRecord("first"),textRecord("second")])
        XCTAssertEqual(try HistoryArchive.decode(archive.encoded()).items.map(\.plainText),["first","second"])
        let store=try HistoryStore(directory:temporary())
        let model=HistoryTransferModel(store:store,policy:{self.unlimited})
        for error in [ArchiveError.invalidRecord,.limitExceeded,.missingPayload] {
            model.fail(ArchiveRecordFailure(index:2,error:error));XCTAssertTrue(model.message!.contains("2"))
        }
        var wrong=textRecord("invalid");wrong.representations=[]
        let encoder=ArchiveDates.encoder()
        XCTAssertThrowsError(try HistoryArchive.decode(encoder.encode(HistoryArchive(items:[textRecord("valid"),wrong])))) { error in
            XCTAssertEqual((error as? ArchiveRecordFailure)?.index,2)
        }
    }
}
#endif
