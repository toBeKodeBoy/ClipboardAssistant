import AppKit
import SQLite3
import Darwin

struct ImportCandidate {
    var id: String
    var record: ArchiveRecord
    var captured: CapturedClipboard
}

struct HistoryImportPlan {
    let revision: Int64
    let policy: RetentionPolicy
    let candidates: [ImportCandidate]
    let existing: [ClipboardItem]
    let doomed: Set<String>
    let fileDuplicates: Int
    let localDuplicates: Int
    var existingEvicted: Int { existing.filter { doomed.contains($0.id) }.count }
    var newEvicted: Int { candidates.filter { doomed.contains($0.id) }.count }
    var retained: Int { candidates.count - newEvicted }
    var total: Int { candidates.count + fileDuplicates + localDuplicates }
    var netChange: Int { retained - existingEvicted }
}

struct ArchiveSnapshotEntry {
    let item: ClipboardItem
    let representations: [StoredRepresentation]
    let files: [FileFingerprint]
    let legacyFileMetadata: Bool
}

final class ArchiveSnapshot {
    let entries: [ArchiveSnapshotEntry]
    private let owner: HistoryStore
    init(entries: [ArchiveSnapshotEntry], owner: HistoryStore) { self.entries = entries; self.owner = owner }
    deinit { owner.releaseArchive(entries.map { $0.item.id }) }
    func record(at index: Int) throws -> ArchiveRecord {
        let entry = entries[index], item = entry.item
        let reps = try entry.representations.map { stored -> ArchiveRepresentation in
            var data: Data?
            if let path = stored.relativePath {
                guard let bytes = owner.data(relativePath: path) else { throw ArchiveError.missingPayload }; data = bytes
            }
            return ArchiveRepresentation(uti: stored.uti, data: data, inlineValue: stored.inlineValue)
        }
        return ArchiveRecord(legacyFileMetadata: entry.legacyFileMetadata, files: entry.files, kind: item.kind, plainText: item.plainText, sourceBundleID: item.sourceBundleID, sourceName: item.sourceName,
            createdAt: item.createdAt, lastUsedAt: item.lastUsedAt, pinned: item.pinned, label: item.label, byteSize: item.byteSize,
            imageWidth: item.imageWidth, imageHeight: item.imageHeight, payloadOversize: item.payloadOversize, representations: reps)
    }
    func write(to destination: URL, plainText: Bool, cancelled: () -> Bool = { false }, progress: (Int, Int) -> Void = { _, _ in }) throws {
        guard !entries.isEmpty else { throw ArchiveError.invalidRecord }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".clipboard-export-" + UUID().uuidString)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp); defer { try? handle.close() }
        let encoder = ArchiveDates.encoder()
        var bytes = 0, payloadBytes = 0, metadataBytes = 0
        func write(_ data: Data) throws {
            bytes += data.count
            guard bytes <= HistoryArchive.maxBytes else { throw ArchiveError.limitExceeded }
            try handle.write(contentsOf: data)
        }
        if !plainText {
            let date = try encoder.encode(Date())
            try write(Data("{\"format\":\"clipboardassistant.history\",\"formatVersion\":1,\"exportedAt\":".utf8) + date + Data(",\"items\":[".utf8))
        }
        for index in entries.indices {
            if cancelled() { throw CancellationError() }
            let record = try self.record(at: index)
            try HistoryArchive(items: [record]).validate()
            payloadBytes += record.plainText.utf8.count + (try record.representations.reduce(0) { $0 + (try $1.payloadByteCount()) })
            guard payloadBytes <= HistoryArchive.maxPayloadBytes else { throw ArchiveError.limitExceeded }
            metadataBytes += record.metadataByteCount
            guard metadataBytes <= 16 * 1024 * 1024 else { throw ArchiveError.limitExceeded }
            if plainText {
                let paths = entries[index].files.map(\.path).joined(separator: "\n")
                let marker = record.payloadOversize ? L10n.text("仅预览", "Preview only") : record.kind.title
                try write(Data("--- \(index + 1) · \(marker) ---\n\(ISO8601DateFormatter().string(from: record.createdAt)) · \(record.sourceName)\n\(record.plainText)\n\(paths)\n\n".utf8))
            } else {
                if index > 0 { try write(Data([44])) }
                try write(encoder.encode(record))
            }
            progress(index + 1, entries.count)
        }
        if !plainText { try write(Data("]}".utf8)) }
        try handle.synchronize()
        if cancelled() { throw CancellationError() }
        // rename atomically replaces an existing file on the same volume.
        guard rename(temp.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try HistoryStore.syncDirectory(destination.deletingLastPathComponent())
    }
}

extension ArchiveRecord {
    func captured() throws -> CapturedClipboard {
        try HistoryArchive(items: [self]).validate()
        if payloadOversize {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let identity = try encoder.encode(PreviewIdentity(kind: kind, text: plainText, size: byteSize, width: imageWidth, height: imageHeight))
            return CapturedClipboard(kind: kind, plainText: plainText, contentHash: "archive-preview-v1:" + ContentHash.sha256(identity), byteSize: byteSize, imageWidth: imageWidth, imageHeight: imageHeight, oversize: true, representations: [])
        }
        var values: [String: Data] = [:]
        for rep in representations {
            if rep.uti == PasteboardUTI.fileURL || rep.uti == PasteboardUTI.filenames {
                guard rep.data == nil, let paths = rep.inlineValue, let files, !files.isEmpty,
                      paths == files.map(\.path).joined(separator: "\n") else { throw ArchiveError.invalidRecord }
            } else {
                guard let data = rep.data, rep.inlineValue == nil else { throw ArchiveError.invalidRecord }; values[rep.uti] = data
            }
        }
        let files = self.files ?? []
        if legacyFileMetadata == true {
            guard !files.isEmpty, files.allSatisfy({ $0.size == 0 && $0.modifiedAt == 0 }),
                  representations.contains(where: { $0.uti == PasteboardUTI.fileURL }) else { throw ArchiveError.invalidRecord }
        }
        guard let built = CaptureBuilder.build(PasteboardSnapshot(items: [PasteboardItemData(values: values)], archivedFiles: files)),
              !built.oversize, built.kind == kind, built.plainText == plainText, built.imageWidth == imageWidth, built.imageHeight == imageHeight, (legacyFileMetadata == true || built.byteSize == byteSize) else { throw ArchiveError.invalidRecord }
        return CapturedClipboard(files: files, kind: kind, plainText: plainText, contentHash: built.contentHash, byteSize: byteSize,
            imageWidth: built.imageWidth, imageHeight: built.imageHeight, oversize: false,
            representations: representations.map { CapturedRepresentation(uti: $0.uti, data: $0.data, inlineValue: $0.inlineValue) })
    }
    private struct PreviewIdentity: Encodable { let kind: ItemKind; let text: String; let size: Int; let width: Int?; let height: Int? }
}

extension HistoryStore {
    func invalidateImportPlans() throws {
        try locked { try database.execute("UPDATE history_revision SET revision=revision+1 WHERE id=1") }
    }
    func archiveItems() throws -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        try database.query("""
            SELECT id,kind,plain_text,content_hash,source_bundle_id,source_name,created_at,last_used_at,pinned,pin_order,byte_size,image_width,image_height,payload_oversize,
                (SELECT label FROM item_labels WHERE item_id=items.id)
            FROM items ORDER BY pinned DESC, COALESCE(pin_order,1000000), last_used_at DESC
            """) { items.append(readItem($0)) }
        return items
    }
    func archiveRevision() throws -> Int64 {
        var value: Int64 = 0
        try database.query("SELECT revision FROM history_revision WHERE id=1") { value = database.int64($0,0) }; return value
    }
    func archiveSnapshot(ids: Set<String>? = nil) throws -> ArchiveSnapshot {
        try locked {
            let items = try archiveItems().filter { ids == nil || ids!.contains($0.id) }
            var entries: [ArchiveSnapshotEntry] = []
            for item in items {
                var reps: [StoredRepresentation] = [], files: [FileFingerprint] = [], legacy = false
                try database.query("SELECT uti,storage,relative_path,inline_value FROM representations WHERE item_id=?", bind: { bindText($0,1,item.id) }) { row in
                    reps.append(StoredRepresentation(uti: database.text(row,0), storage: database.text(row,1), relativePath: database.optionalText(row,2), inlineValue: database.optionalText(row,3)))
                }
                var metadata: String?
                try database.query("SELECT metadata FROM item_files WHERE item_id=?", bind: { bindText($0,1,item.id) }) { metadata = database.text($0,0) }
                if let metadata { let stored = try JSONDecoder().decode(StoredFileMetadata.self, from: Data(metadata.utf8)); files = stored.files; legacy = stored.incomplete }
                else if let paths = reps.first(where: { $0.uti == PasteboardUTI.fileURL })?.inlineValue {
                    // Older databases never stored file attributes. Preserve references without reading files.
                    legacy = true
                    files = paths.split(separator: "\n").map { FileFingerprint(path: String($0), size: 0, modifiedAt: 0) }
                }
                entries.append(ArchiveSnapshotEntry(item: item, representations: reps, files: files, legacyFileMetadata: legacy))
            }
            for item in items { payloadLeases[item.id, default: 0] += 1 }
            return ArchiveSnapshot(entries: entries, owner: self)
        }
    }
    func releaseArchive(_ ids: [String]) {
        locked {
            for id in ids {
                guard let leases = payloadLeases[id] else { continue }
                let count = leases - 1
                if count > 0 { payloadLeases[id] = count }
                else {
                    payloadLeases.removeValue(forKey: id)
                    if pendingPayloadDeletes.remove(id) != nil { payloads.removeItem(id: id) }
                }
            }
        }
    }
    func removePayload(id: String) {
        if payloadLeases[id] != nil { pendingPayloadDeletes.insert(id) }
        else { payloads.removeItem(id: id) }
    }
    func previewImport(_ archive: HistoryArchive, policy: RetentionPolicy, now: Date = Date(), cancelled: () -> Bool = { false }) throws -> HistoryImportPlan {
        try archive.validate(now: now, cancelled: cancelled)
        var seen = Set<String>(), candidates: [ImportCandidate] = [], fileDuplicates = 0
        for record in archive.items {
            if cancelled() { throw CancellationError() }
            let captured = try record.captured()
            if !seen.insert(captured.contentHash).inserted { fileDuplicates += 1; continue }
            candidates.append(ImportCandidate(id: UUID().uuidString, record: record, captured: captured))
        }
        return try locked {
            let existing = try archiveItems()
            var hashes = Set(existing.map(\.contentHash))
            for item in existing where item.kind == .file {
                var metadataExists = false
                try database.query("SELECT item_id FROM item_files WHERE item_id=?", bind: { bindText($0,1,item.id) }) { _ in metadataExists = true }
                if !metadataExists {
                    try database.query("SELECT inline_value FROM representations WHERE item_id=? AND uti=?", bind: { bindText($0,1,item.id); bindText($0,2,PasteboardUTI.fileURL) }) { row in
                        let paths = database.text(row,0).split(separator: "\n").map { FileFingerprint(path: String($0), size: 0, modifiedAt: 0) }
                        hashes.insert(ContentHash.files(paths))
                    }
                }
            }
            let localDuplicates = candidates.filter { hashes.contains($0.captured.contentHash) }.count
            candidates.removeAll { hashes.contains($0.captured.contentHash) }
            let doomed = candidates.isEmpty ? [] : retentionIDs(existing + candidates.map { $0.item }, policy: policy, now: now)
            return HistoryImportPlan(revision: try archiveRevision(), policy: policy, candidates: candidates, existing: existing, doomed: doomed, fileDuplicates: fileDuplicates, localDuplicates: localDuplicates)
        }
    }
    func retentionIDs(_ items: [ClipboardItem], policy: RetentionPolicy, now: Date) -> Set<String> {
        var doomed = Set(policy.expiredAndOverflowIDs(in: items, now: now))
        doomed.formUnion(policy.imageOverflowIDs(in: items.filter { !doomed.contains($0.id) })); return doomed
    }
    /// Hook injects failures at storage boundaries; production leaves it empty.
    func commitImport(_ plan: HistoryImportPlan, policy: RetentionPolicy, allowExistingEviction: Bool, now: Date = Date(), checkpoint: (String) throws -> Void = { _ in }) throws -> Int {
        try locked {
            guard plan.policy == policy, plan.revision == (try archiveRevision()) else { throw ArchiveError.stalePlan }
            guard !plan.candidates.isEmpty else { return 0 }
            guard plan.doomed == retentionIDs(plan.existing + plan.candidates.map { $0.item }, policy: policy, now: now),
                  plan.existingEvicted == 0 || allowExistingEviction else { throw ArchiveError.stalePlan }
            let job = UUID().uuidString
            let stage = directory.appendingPathComponent("staging/" + job)
            var newIDs: [String] = []
            try database.run("INSERT INTO archive_jobs VALUES (?,0)") { bindText($0,1,job) }
            do {
                let staged = try PayloadStore(root: stage)
                for candidate in plan.candidates where !plan.doomed.contains(candidate.id) {
                    newIDs.append(candidate.id)
                    for rep in candidate.captured.representations {
                        if let data = rep.data {
                            let path = try staged.write(itemID: candidate.id, uti: rep.uti, data: data)
                            let file = try FileHandle(forWritingTo: staged.fileURL(relativePath: path)); try file.synchronize(); try file.close()
                        }
                    }
                    try checkpoint("payload-written")
                    let source = stage.appendingPathComponent("payloads/" + candidate.id)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try Self.syncDirectory(source)
                        try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent("payloads/" + candidate.id))
                    }
                    try checkpoint("payload-moved")
                }
                try Self.syncDirectory(directory.appendingPathComponent("payloads"))
                try database.execute("BEGIN IMMEDIATE")
                do {
                    var order = try nextPinOrder()
                    for candidate in plan.candidates where !plan.doomed.contains(candidate.id) {
                        try insertArchive(candidate, pinOrder: order)
                        if candidate.record.pinned { order += 1 }
                    }
                    for item in plan.existing where plan.doomed.contains(item.id) {
                        try database.run("INSERT OR IGNORE INTO archive_cleanup VALUES (?)") { bindText($0,1,item.id) }
                        try database.run("DELETE FROM items WHERE id=?") { bindText($0,1,item.id) }
                    }
                    try database.run("UPDATE archive_jobs SET committed=1 WHERE id=?") { bindText($0,1,job) }
                    try checkpoint("before-commit")
                    try database.execute("COMMIT")
                } catch { try? database.execute("ROLLBACK"); throw error }
            } catch {
                newIDs.forEach { payloads.removeItem(id: $0) }
                try? FileManager.default.removeItem(at: stage)
                try? database.run("DELETE FROM archive_jobs WHERE id=?") { bindText($0,1,job) }
                throw error
            }
            for candidate in plan.candidates where !plan.doomed.contains(candidate.id) {
                if let image = candidate.captured.representations.first(where: { PasteboardUTI.imageTypes.contains($0.uti) })?.data {
                    _ = payloads.writeThumbnail(itemID: candidate.id, imageData: image)
                }
            }
            // Once committed, a cleanup failure must never turn success into a rollback report.
            try? checkpoint("after-commit")
            try? cleanupArchives()
            try? FileManager.default.removeItem(at: stage)
            try? database.run("DELETE FROM archive_jobs WHERE id=?") { bindText($0,1,job) }
            return plan.retained
        }
    }
    private func insertArchive(_ candidate: ImportCandidate, pinOrder: Int64) throws {
        let r = candidate.record, c = candidate.captured, id = candidate.id
        try database.run("INSERT INTO items VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)") { s in
            bindText(s,1,id); bindText(s,2,r.kind.rawValue); bindText(s,3,r.plainText); bindText(s,4,c.contentHash)
            bindText(s,5,r.sourceBundleID); bindText(s,6,r.sourceName)
            sqlite3_bind_double(s,7,r.createdAt.timeIntervalSince1970); sqlite3_bind_double(s,8,r.lastUsedAt.timeIntervalSince1970)
            sqlite3_bind_int(s,9,r.pinned ? 1 : 0)
            if r.pinned { sqlite3_bind_int64(s,10,pinOrder) } else { sqlite3_bind_null(s,10) }
            sqlite3_bind_int64(s,11,Int64(r.byteSize))
            if let width = r.imageWidth { sqlite3_bind_int64(s,12,Int64(width)) } else { sqlite3_bind_null(s,12) }
            if let height = r.imageHeight { sqlite3_bind_int64(s,13,Int64(height)) } else { sqlite3_bind_null(s,13) }
            sqlite3_bind_int(s,14,r.payloadOversize ? 1 : 0)
        }
        if let label = r.label { try database.run("INSERT INTO item_labels VALUES (?,?)") { bindText($0,1,id); bindText($0,2,label) } }
        if let files = r.files, !files.isEmpty {
            let json = String(decoding: try JSONEncoder().encode(StoredFileMetadata(files: files, incomplete: r.legacyFileMetadata == true)), as: UTF8.self)
            try database.run("INSERT INTO item_files VALUES (?,?)") { bindText($0,1,id); bindText($0,2,json) }
        }
        for rep in c.representations {
            let path = rep.data == nil ? nil : "payloads/\(id)/\(PayloadStore.fileName(for: rep.uti))"
            try database.run("INSERT INTO representations VALUES (?,?,?,?,?)") { s in
                bindText(s,1,id); bindText(s,2,rep.uti); bindText(s,3,path == nil ? "inline" : "file"); bindText(s,4,path); bindText(s,5,rep.inlineValue)
            }
        }
    }
    func cleanupArchives() throws {
        var ids: [String] = []
        try database.query("SELECT item_id FROM archive_cleanup") { ids.append(database.text($0,0)) }
        for id in ids {
            var referenced = false
            try database.query("SELECT id FROM items WHERE id=?", bind: { bindText($0,1,id) }) { _ in referenced = true }
            if !referenced { removePayload(id: id) }
            try database.run("DELETE FROM archive_cleanup WHERE item_id=?") { bindText($0,1,id) }
        }
    }
    func recoverArchives() throws {
        try locked {
            try cleanupArchives()
            let keep = Set(try archiveItems().map(\.id))
            for folder in ["payloads", "thumbs", "staging"] {
                let root = directory.appendingPathComponent(folder)
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    let id = folder == "thumbs" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
                    if UUID(uuidString: id) != nil && (folder == "staging" || !keep.contains(id)) { try FileManager.default.removeItem(at: url) }
                }
            }
            try database.execute("DELETE FROM archive_jobs")
        }
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

extension ImportCandidate {
    var item: ClipboardItem {
        ClipboardItem(id: id, kind: record.kind, plainText: record.plainText, contentHash: captured.contentHash, sourceBundleID: record.sourceBundleID,
            sourceName: record.sourceName, createdAt: record.createdAt, lastUsedAt: record.lastUsedAt, pinned: record.pinned, pinOrder: nil,
            byteSize: record.byteSize, imageWidth: record.imageWidth, imageHeight: record.imageHeight, label: record.label, payloadOversize: record.payloadOversize)
    }
}

#if DEBUG
/// Runs only when explicitly invoked by crash-recovery integration tests; never reads a pasteboard.
enum ArchiveCrashHarness {
    static let argument = "--clipboard-archive-crash-test"
    static func runIfRequested(_ arguments: [String], crash: (Int32) -> Void = { Darwin._exit($0) }) -> Bool {
        guard arguments.count == 4, arguments[1] == argument else { return false }
        do {
            let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
            let store = try HistoryStore(directory: directory)
            let archive = try ArchiveStream.read(directory.appendingPathComponent("crash-input.json"))
            let policy = RetentionPolicy(maxCount: nil, maxAge: nil, maxImageBytes: RetentionPolicy.imageCap)
            let plan = try store.previewImport(archive, policy: policy)
            _ = try store.commitImport(plan, policy: policy, allowExistingEviction: false) { phase in
                if phase == arguments[3] { crash(99) }
            }
        } catch { crash(98) }
        return true
    }
}
#endif
