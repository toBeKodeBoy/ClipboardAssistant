import AppKit
import Foundation

enum PasteboardUTI {
    static let plain = "public.utf8-plain-text"
    static let utf16 = "public.utf16-plain-text"
    static let rtf = "public.rtf"
    static let html = "public.html"
    static let url = "public.url"
    static let png = "public.png"
    static let tiff = "public.tiff"
    static let jpeg = "public.jpeg"
    static let fileURL = "public.file-url"
    static let concealed = "org.nspasteboard.ConcealedType"
    static let transient = "org.nspasteboard.TransientType"
    static let remote = "com.apple.is-remote-clipboard"
    static let filenames = "NSFilenamesPboardType"

    static let imageTypes: Set<String> = [png, tiff, jpeg]
    static let markers: Set<String> = [concealed, transient, remote]
    static let captured: Set<String> = [
        plain, utf16, rtf, html, url, png, tiff, jpeg, fileURL, filenames
    ]
}

struct PasteboardItemData: Equatable {
    var values: [String: Data]
    var fullDigests: [String: String] = [:]
    var fullByteCounts: [String: Int] = [:]
}

struct PasteboardSnapshot: Equatable {
    var items: [PasteboardItemData]

    var hasConcealedMarker: Bool {
        items.contains { $0.values.keys.contains(PasteboardUTI.concealed) }
    }

    var hasTransientMarker: Bool {
        items.contains { $0.values.keys.contains(PasteboardUTI.transient) }
    }

    var hasRemoteMarker: Bool {
        items.contains { $0.values.keys.contains(PasteboardUTI.remote) }
    }
}

struct CaptureLimits: Equatable {
    var maxTextBytes: Int = 1_048_576
    var maxImageBytes: Int = 10 * 1024 * 1024
    var previewBytes: Int = 4_096
}

struct CapturedRepresentation: Equatable {
    var uti: String
    var data: Data?
    var inlineValue: String?
}

struct CapturedClipboard: Equatable {
    var kind: ItemKind
    var plainText: String
    var contentHash: String
    var byteSize: Int
    var imageWidth: Int?
    var imageHeight: Int?
    var oversize: Bool
    var representations: [CapturedRepresentation]
}

enum CaptureBuilder {
    static func build(_ snapshot: PasteboardSnapshot, limits: CaptureLimits = CaptureLimits()) -> CapturedClipboard? {
        let values = merged(snapshot)
        let digests = mergedDigests(snapshot)
        let counts = mergedCounts(snapshot)
        let plain = plainText(from: values)
        let fileEntries = fileFingerprints(in: snapshot)
        let image = imagePayload(from: values)
        let hasRich = values[PasteboardUTI.rtf] != nil || values[PasteboardUTI.html] != nil || digests[PasteboardUTI.rtf] != nil || digests[PasteboardUTI.html] != nil
        let textBytes = counts[PasteboardUTI.plain] ?? counts[PasteboardUTI.utf16] ?? (plain?.utf8.count ?? 0)
        let imageBytes = counts[PasteboardUTI.png] ?? counts[PasteboardUTI.tiff] ?? counts[PasteboardUTI.jpeg] ?? (image?.data.count ?? 0)
        let hadImage = image != nil || imageBytes > 0
        if plain == nil && fileEntries.isEmpty && !hadImage && !hasRich {
            return nil
        }

        let textOversize = textBytes > limits.maxTextBytes
        let imageOversize = imageBytes > limits.maxImageBytes
        let oversize = textOversize || imageOversize
        let displayText = displayText(plain: plain, files: fileEntries, limits: limits, textOversize: textOversize)
        let kind = kindFor(hasRich: hasRich, hadImage: hadImage, files: fileEntries)
        let hash = hashFor(plain: plain ?? "", values: values, digests: digests, image: image, files: fileEntries, imageOversize: imageOversize)
        let byteSize = byteSizeFor(plain: plain, image: image, files: fileEntries, counts: counts)

        return CapturedClipboard(
            kind: kind,
            plainText: displayText,
            contentHash: hash,
            byteSize: byteSize,
            imageWidth: image?.width,
            imageHeight: image?.height,
            oversize: oversize,
            representations: oversize ? [] : representations(from: values, files: fileEntries)
        )
    }

    private static func merged(_ snapshot: PasteboardSnapshot) -> [String: Data] {
        var values: [String: Data] = [:]
        for item in snapshot.items {
            for (key, data) in item.values where values[key] == nil {
                values[key] = data
            }
        }
        return values
    }

    private static func mergedDigests(_ snapshot: PasteboardSnapshot) -> [String: String] {
        var digests: [String: String] = [:]
        for item in snapshot.items {
            for (key, digest) in item.fullDigests where digests[key] == nil {
                digests[key] = digest
            }
        }
        return digests
    }

    private static func mergedCounts(_ snapshot: PasteboardSnapshot) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in snapshot.items {
            for (key, count) in item.fullByteCounts where counts[key] == nil {
                counts[key] = count
            }
        }
        return counts
    }

    private static func plainText(from values: [String: Data]) -> String? {
        if let data = values[PasteboardUTI.plain], let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let data = values[PasteboardUTI.utf16], let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let data = values[PasteboardUTI.url], let text = String(data: data, encoding: .utf8) {
            return text
        }
        return nil
    }

    private static func imagePayload(from values: [String: Data]) -> (data: Data, width: Int?, height: Int?)? {
        let data = values[PasteboardUTI.png] ?? values[PasteboardUTI.tiff] ?? values[PasteboardUTI.jpeg]
        guard let data, !data.isEmpty else { return nil }
        let size = ImageSizing.pixelSize(of: data)
        return (data, size?.width, size?.height)
    }

    private static func fileFingerprints(in snapshot: PasteboardSnapshot) -> [FileFingerprint] {
        var paths: [String] = []
        for item in snapshot.items {
            if let data = item.values[PasteboardUTI.fileURL], let text = String(data: data, encoding: .utf8) {
                paths.append(contentsOf: text.split(separator: "\n").map(String.init))
            }
            if let data = item.values[PasteboardUTI.filenames],
               let names = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                paths.append(contentsOf: names)
            }
        }
        var seen = Set<String>()
        return paths.compactMap { part in
            let url: URL
            if let parsed = URL(string: part), parsed.isFileURL {
                url = parsed
            } else if part.hasPrefix("/") {
                url = URL(fileURLWithPath: part)
            } else {
                return nil
            }
            let path = url.path
            if !seen.insert(path).inserted { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return FileFingerprint(path: path, size: size, modifiedAt: Int64(modified))
        }
    }

    private static func displayText(plain: String?, files: [FileFingerprint], limits: CaptureLimits, textOversize: Bool) -> String {
        if !files.isEmpty {
            return files.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: "\n")
        }
        let text = plain ?? ""
        if textOversize {
            let end = text.index(text.startIndex, offsetBy: min(limits.previewBytes, text.count), limitedBy: text.endIndex) ?? text.endIndex
            return String(text[..<end])
        }
        return text
    }

    private static func kindFor(hasRich: Bool, hadImage: Bool, files: [FileFingerprint]) -> ItemKind {
        let hasFiles = !files.isEmpty
        if hadImage && hasFiles { return .mixed }
        if hasFiles { return .file }
        if hadImage { return .image }
        if hasRich { return .rich }
        return .text
    }

    private static func hashFor(
        plain: String,
        values: [String: Data],
        digests: [String: String],
        image: (data: Data, width: Int?, height: Int?)?,
        files: [FileFingerprint],
        imageOversize: Bool
    ) -> String {
        if let digest = digests[PasteboardUTI.png] ?? digests[PasteboardUTI.tiff] ?? digests[PasteboardUTI.jpeg] {
            return digest
        }
        if !files.isEmpty && image == nil && !imageOversize {
            return ContentHash.files(files)
        }
        if let image, !imageOversize, files.isEmpty {
            return ContentHash.imageData(image.data)
        }
        if let digest = digests[PasteboardUTI.plain] ?? digests[PasteboardUTI.utf16] {
            return digest
        }
        if plain.isEmpty && files.isEmpty && image == nil {
            if let digest = digests[PasteboardUTI.rtf] ?? digests[PasteboardUTI.html] {
                return digest
            }
            if let rich = values[PasteboardUTI.rtf] ?? values[PasteboardUTI.html] {
                return ContentHash.sha256(rich)
            }
        }
        if let image {
            return ContentHash.sha256(image.data + Data(ContentHash.normalizeText(plain).utf8))
        }
        return ContentHash.text(plain)
    }

    private static func byteSizeFor(
        plain: String?,
        image: (data: Data, width: Int?, height: Int?)?,
        files: [FileFingerprint],
        counts: [String: Int]
    ) -> Int {
        if let count = counts[PasteboardUTI.png] ?? counts[PasteboardUTI.tiff] ?? counts[PasteboardUTI.jpeg] {
            return count
        }
        if let count = counts[PasteboardUTI.plain] ?? counts[PasteboardUTI.utf16] {
            return count
        }
        if let image { return image.data.count }
        if !files.isEmpty { return Int(files.reduce(Int64(0)) { $0 + $1.size }) }
        return plain?.utf8.count ?? 0
    }

    private static func representations(from values: [String: Data], files: [FileFingerprint]) -> [CapturedRepresentation] {
        var result: [CapturedRepresentation] = []
        let skipped: Set<String> = [
            PasteboardUTI.concealed,
            PasteboardUTI.transient,
            PasteboardUTI.remote,
            PasteboardUTI.fileURL,
            PasteboardUTI.filenames
        ]
        for (uti, data) in values where !skipped.contains(uti) {
            result.append(CapturedRepresentation(uti: uti, data: data, inlineValue: nil))
        }
        if !files.isEmpty {
            let paths = files.map(\.path).joined(separator: "\n")
            result.append(CapturedRepresentation(uti: PasteboardUTI.fileURL, data: nil, inlineValue: paths))
        }
        return result.sorted { $0.uti < $1.uti }
    }
}

enum ImageSizing {
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}
