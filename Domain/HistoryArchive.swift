import Foundation

enum ArchiveError: Error { case invalidFormat, limitExceeded, invalidRecord, missingPayload, stalePlan }
struct ArchiveRepresentation: Codable, Equatable {
    var uti: String
    var data: Data?
    var inlineValue: String?
}
struct ArchiveRecord: Codable, Equatable {
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
    static let maxBytes = 64 * 1024 * 1024
    static let allowedTypes: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text", "public.rtf", "public.html", "public.url", "public.png", "public.tiff", "public.jpeg", "public.file-url", "NSFilenamesPboardType"]
    func validate(now: Date = Date()) throws {
        guard format == "clipboardassistant.history", formatVersion == 1 else { throw ArchiveError.invalidFormat }
        guard items.count <= 10000 else { throw ArchiveError.limitExceeded }
        var total = 0
        for item in items {
            guard item.byteSize >= 0, item.plainText.utf8.count <= 1048576,
                  item.sourceName.utf8.count <= 1024, (item.sourceBundleID?.utf8.count ?? 0) <= 255,
                  item.createdAt.timeIntervalSince1970 >= 0, item.lastUsedAt.timeIntervalSince1970 >= 0,
                  item.createdAt <= now.addingTimeInterval(86400), item.lastUsedAt <= now.addingTimeInterval(86400),
                  item.representations.count <= 10 else { throw ArchiveError.invalidRecord }
            if let label = item.label { _ = try AppTagRule(bundleID: "archive", label: label) }
            if item.payloadOversize && !item.representations.isEmpty { throw ArchiveError.invalidRecord }
            if !item.payloadOversize && item.representations.isEmpty { throw ArchiveError.missingPayload }
            var types = Set<String>()
            for rep in item.representations {
                guard Self.allowedTypes.contains(rep.uti), types.insert(rep.uti).inserted,
                      (rep.data != nil) != (rep.inlineValue != nil) else { throw ArchiveError.invalidRecord }
                let count = rep.data?.count ?? rep.inlineValue?.utf8.count ?? 0
                guard count <= (rep.uti == "public.png" || rep.uti == "public.tiff" || rep.uti == "public.jpeg" ? 10485760 : 1048576) else { throw ArchiveError.limitExceeded }
                total += count
                guard total <= Self.maxBytes else { throw ArchiveError.limitExceeded }
            }
        }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBytes else { throw ArchiveError.limitExceeded }
        return data
    }
    static func decode(_ data: Data) throws -> HistoryArchive {
        guard data.count <= maxBytes else { throw ArchiveError.limitExceeded }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Self.self, from: data)
        try archive.validate(); return archive
    }
    func plainTextExport() -> String {
        let date = ISO8601DateFormatter()
        return items.enumerated().map { index, item in
            let marker = item.payloadOversize ? " [Preview only / 仅预览]" : ""
            return "--- \(index + 1)\(marker) ---\n\(date.string(from: item.createdAt)) · \(item.sourceName)\n\(item.plainText)\n"
        }.joined(separator: "\n")
    }
}
