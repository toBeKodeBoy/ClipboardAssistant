import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

enum ArchiveError: Error { case invalidFormat, limitExceeded, invalidRecord, missingPayload, stalePlan }
struct ArchiveRepresentation: Codable, Equatable {
    var uti: String
    var data: Data?
    var inlineValue: String?
    func payloadByteCount() throws -> Int {
        switch (data, inlineValue) {
        case (let data?, nil): return data.count
        case (nil, let text?): return text.utf8.count
        default: throw ArchiveError.invalidRecord
        }
    }
}
struct ArchiveRecord: Codable, Equatable {
    var legacyFileMetadata: Bool? = nil
    var files: [FileFingerprint]? = nil
    var kind: ItemKind
    var plainText: String
    var sourceBundleID: String?
    var sourceName: String
    var createdAt: Date
    var lastUsedAt: Date
    var pinned: Bool
    var label: String?
    var byteSize: Int
    var imageWidth: Int?
    var imageHeight: Int?
    var payloadOversize: Bool
    var representations: [ArchiveRepresentation]
}
struct HistoryArchive: Codable {
    var format = "clipboardassistant.history"
    var formatVersion = 1
    var exportedAt = Date()
    var items: [ArchiveRecord]
    static let maxBytes = 512 * 1024 * 1024
    static let maxPayloadBytes = 256 * 1024 * 1024
    static let allowedTypes: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text", "public.rtf", "public.html", "public.url", "public.png", "public.tiff", "public.jpeg", "public.file-url", "NSFilenamesPboardType"]
    func validate(now: Date = Date(), cancelled: () -> Bool = { false }) throws {
        guard format == "clipboardassistant.history", formatVersion == 1 else { throw ArchiveError.invalidFormat }
        guard exportedAt.timeIntervalSince1970.isFinite, exportedAt.timeIntervalSince1970 >= 0, exportedAt <= now.addingTimeInterval(86400) else { throw ArchiveError.invalidRecord }
        guard items.count <= 10000 else { throw ArchiveError.limitExceeded }
        var total = 0
        var metadataBytes = 0
        for item in items {
            if cancelled() { throw CancellationError() }
            guard item.byteSize >= 0, item.byteSize <= 2_147_483_647, item.plainText.utf8.count <= 1048576,
                  item.sourceName.utf8.count <= 1024, (item.sourceBundleID?.utf8.count ?? 0) <= 255,
                  item.createdAt.timeIntervalSince1970.isFinite, item.lastUsedAt.timeIntervalSince1970.isFinite,
                  item.createdAt.timeIntervalSince1970 >= 0, item.lastUsedAt.timeIntervalSince1970 >= 0,
                  item.createdAt <= now.addingTimeInterval(86400), item.lastUsedAt <= now.addingTimeInterval(86400),
                  item.representations.count <= 10 else { throw ArchiveError.invalidRecord }
            metadataBytes += item.metadataByteCount
            if let files = item.files {
                guard files.count <= 1000, Set(files.map(\.path)).count == files.count else { throw ArchiveError.invalidRecord }
                for file in files {
                    guard file.path.hasPrefix("/"), !file.path.contains("\0"), !file.path.contains("\n"), file.path.utf8.count <= 4096,
                          !file.path.split(separator: "/").contains(".."), file.size >= 0, file.size <= 2_147_483_647, file.modifiedAt >= 0 else { throw ArchiveError.invalidRecord }
                }
            }
            guard metadataBytes <= 16 * 1024 * 1024 else { throw ArchiveError.limitExceeded }
            total += item.plainText.utf8.count
            guard total <= Self.maxPayloadBytes else { throw ArchiveError.limitExceeded }
            if let width = item.imageWidth {
                guard let height = item.imageHeight, width > 0, height > 0, height <= 40_000_000, width <= 40_000_000 / height else { throw ArchiveError.invalidRecord }
            } else if item.imageHeight != nil { throw ArchiveError.invalidRecord }
            if let label = item.label {
                // Retain labels only as legacy archive metadata, never as active capture rules.
                guard !label.isEmpty, label.utf8.count <= 4096, label.count <= 30,
                      !label.contains(where: \.isNewline),
                      label.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping == label else { throw ArchiveError.invalidRecord }
            }
            if item.payloadOversize && !item.representations.isEmpty { throw ArchiveError.invalidRecord }
            if !item.payloadOversize && item.representations.isEmpty { throw ArchiveError.missingPayload }
            var types = Set<String>()
            for rep in item.representations {
                guard Self.allowedTypes.contains(rep.uti), types.insert(rep.uti).inserted else { throw ArchiveError.invalidRecord }
                let count = try rep.payloadByteCount()
                guard count <= (rep.uti == "public.png" || rep.uti == "public.tiff" || rep.uti == "public.jpeg" ? 10485760 : 1048576) else { throw ArchiveError.limitExceeded }
                #if canImport(ImageIO)
                if ["public.png", "public.tiff", "public.jpeg"].contains(rep.uti) {
                    guard let data = rep.data, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, height <= 40_000_000, width <= 40_000_000 / height,
                          item.imageWidth == width, item.imageHeight == height,
                          CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { throw ArchiveError.invalidRecord }
                }
                #endif
                total += count
                guard total <= Self.maxPayloadBytes else { throw ArchiveError.limitExceeded }
            }
        }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = ArchiveDates.encoder()
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBytes else { throw ArchiveError.limitExceeded }
        return data
    }
    static func decode(_ data: Data) throws -> HistoryArchive {
        guard data.count <= maxBytes else { throw ArchiveError.limitExceeded }
        return try ArchiveStream(data: data).read()
    }
    func plainTextExport() -> String {
        let date = ISO8601DateFormatter()
        return items.enumerated().map { index, item in
            let marker = item.payloadOversize ? " [Preview only / 仅预览]" : ""
            return "--- \(index + 1)\(marker) ---\n\(date.string(from: item.createdAt)) · \(item.sourceName)\n\(item.plainText)\n"
        }.joined(separator: "\n")
    }
}

/**
 * 文件去重指纹。
 *
 * 只记录路径、大小和修改时间，不保存文件内容。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct FileFingerprint: Codable, Equatable {
    /** 文件绝对路径。 */
    var path: String
    /** 文件字节大小。 */
    var size: Int64
    /** 修改时间，单位为秒。 */
    var modifiedAt: Int64
}

struct StoredFileMetadata: Codable {
    var files: [FileFingerprint]
    var incomplete: Bool
}

extension ArchiveRecord {
    var metadataByteCount: Int {
        sourceName.utf8.count + (sourceBundleID?.utf8.count ?? 0) + (label?.utf8.count ?? 0)
            + (files?.reduce(0) { $0 + $1.path.utf8.count } ?? 0)
    }
}

enum ArchiveWire {
    static func validateRecord(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["legacyFileMetadata", "files", "kind", "plainText", "sourceBundleID", "sourceName", "createdAt", "lastUsedAt", "pinned", "label", "byteSize", "imageWidth", "imageHeight", "payloadOversize", "representations"]) else { throw ArchiveError.invalidRecord }
        if let reps = object["representations"] as? [[String: Any]] {
            for rep in reps { guard Set(rep.keys).isSubset(of: ["uti", "data", "inlineValue"]) else { throw ArchiveError.invalidRecord } }
        }
        if let files = object["files"] as? [[String: Any]] {
            for file in files { guard Set(file.keys).isSubset(of: ["path", "size", "modifiedAt"]) else { throw ArchiveError.invalidRecord } }
        }
    }
}

struct ArchiveRecordFailure: Error {
    enum Category { case invalid, resourceLimit, missingPayload }
    let index: Int
    let category: Category
    init(index: Int, error: Error) {
        self.index = index
        switch error {
        case ArchiveError.limitExceeded: category = .resourceLimit
        case ArchiveError.missingPayload: category = .missingPayload
        default: category = .invalid
        }
    }
}

/// UTC ISO 8601 with nanosecond digits preserves SQLite's Double timestamps.
/// Older backups without fractional seconds remain readable.
enum ArchiveDates {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.timeZone = TimeZone(secondsFromGMT: 0)
        value.formatOptions = [.withInternetDateTime]; return value
    }()
    static func string(_ date: Date) -> String {
        let timestamp = date.timeIntervalSince1970
        var whole = floor(timestamp), nanos = Int(((timestamp - whole) * 1_000_000_000).rounded())
        if nanos == 1_000_000_000 { whole += 1; nanos = 0 }
        lock.lock(); let base = formatter.string(from: Date(timeIntervalSince1970: whole)); lock.unlock()
        return String(base.dropLast()) + String(format: ".%09dZ", nanos)
    }
    static func date(_ string: String) -> Date? {
        guard string.utf8.count <= 64 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let date = formatter.date(from: string) { return date }
        guard string.hasSuffix("Z"), let dot = string.firstIndex(of: ".") else { return nil }
        let digits = string[string.index(after: dot)..<string.index(before: string.endIndex)]
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let nanos = Double("0." + digits), let base = formatter.date(from: String(string[..<dot]) + "Z") else { return nil }
        return Date(timeIntervalSince1970: base.timeIntervalSince1970 + nanos)
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer(); try container.encode(string(date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            guard let result = date(try container.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid archive date")
            }
            return result
        }
        return decoder
    }
}
