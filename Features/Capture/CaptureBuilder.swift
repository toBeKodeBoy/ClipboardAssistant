import AppKit
import Foundation

/**
 * 采集关心的剪切板类型标识。
 *
 * 只读取列表中的类型。机密、临时和远程标记只用于判断，不作为可粘贴负载保存。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum PasteboardUTI {
    /** UTF-8 纯文本。 */
    static let plain = "public.utf8-plain-text"
    /** UTF-16 纯文本。 */
    static let utf16 = "public.utf16-plain-text"
    /** RTF 富文本。 */
    static let rtf = "public.rtf"
    /** HTML。 */
    static let html = "public.html"
    /** URL。 */
    static let url = "public.url"
    /** PNG。 */
    static let png = "public.png"
    /** TIFF。 */
    static let tiff = "public.tiff"
    /** JPEG。 */
    static let jpeg = "public.jpeg"
    /** 文件 URL。 */
    static let fileURL = "public.file-url"
    /** 机密标记。 */
    static let concealed = "org.nspasteboard.ConcealedType"
    /** 临时标记，命中后整次采集跳过。 */
    static let transient = "org.nspasteboard.TransientType"
    /** 其他设备经通用剪贴板同步过来的标记。 */
    static let remote = "com.apple.is-remote-clipboard"
    /** 旧式文件名列表。 */
    static let filenames = "NSFilenamesPboardType"

    /** 图片类型。 */
    static let imageTypes: Set<String> = [png, tiff, jpeg]
    /** 只参与跳过或来源判断、不作为正文保存的标记。 */
    static let markers: Set<String> = [concealed, transient, remote]
    /** 允许读取的内容类型。 */
    static let captured: Set<String> = [
        plain, utf16, rtf, html, url, png, tiff, jpeg, fileURL, filenames
    ]
}

/**
 * 一个剪切板项上已读取的数据。
 *
 * 超限类型不保存全文，只留下全文哈希和原文字节数，values 里至多保留预览。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct PasteboardItemData: Equatable {
    /** 已读取或截断后的类型数据。 */
    var values: [String: Data]
    /** 超限类型的全文 SHA-256，键为 UTI。 */
    var fullDigests: [String: String] = [:]
    /** 超限类型的原文字节数，键为 UTI。 */
    var fullByteCounts: [String: Int] = [:]
}

/**
 * 一次剪切板读取结果。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct PasteboardSnapshot: Equatable {
    /** 剪切板上的各项。 */
    var items: [PasteboardItemData]

    /**
     * 是否带机密标记。
     *
     * @return 任一项带 ConcealedType 时返回 true
     */
    var hasConcealedMarker: Bool {
        items.contains { $0.values.keys.contains(PasteboardUTI.concealed) }
    }

    /**
     * 是否带临时标记。
     *
     * @return 任一项带 TransientType 时返回 true
     */
    var hasTransientMarker: Bool {
        items.contains { $0.values.keys.contains(PasteboardUTI.transient) }
    }

    /**
     * 是否来自通用剪贴板同步。
     *
     * @return 任一项带远程标记时返回 true
     */
    var hasRemoteMarker: Bool {
        items.contains { $0.values.keys.contains(PasteboardUTI.remote) }
    }
}

/**
 * 单条内容的采集上限。
 *
 * 文本超过 1MB 或图片超过 10MB 时，先对原文哈希，再只保留预览。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct CaptureLimits: Equatable {
    /** 单条文本上限，默认 1MB。 */
    var maxTextBytes: Int = 1_048_576
    /** 单条图片上限，默认 10MB。 */
    var maxImageBytes: Int = 10 * 1024 * 1024
    /** 超限文本保留的预览字节数。 */
    var previewBytes: Int = 4_096
}

/**
 * 准备写入存储的一种剪切板表示。
 *
 * data 与 inlineValue 二选一。文件路径放在 inlineValue，不复制文件内容。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct CapturedRepresentation: Equatable {
    /** 剪切板类型标识。 */
    var uti: String
    /** 二进制负载。超限条目为空。 */
    var data: Data?
    /** 直接存入数据库的短文本，例如文件路径列表。 */
    var inlineValue: String?
}

/**
 * 一次采集整理后的结果。
 *
 * 尚未写入数据库。相同 contentHash 由存储层合并。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct CapturedClipboard: Equatable {
    /** 内容类型。 */
    var kind: ItemKind
    /** 搜索和预览用的纯文本。超限时只含预览。 */
    var plainText: String
    /** 去重哈希。超限内容使用原文摘要，避免不同大文本并成一条。 */
    var contentHash: String
    /** 原文或图片字节数。 */
    var byteSize: Int
    /** 图片宽度。 */
    var imageWidth: Int?
    /** 图片高度。 */
    var imageHeight: Int?
    /** 是否超过单条上限。为 true 时 representations 为空，不能恢复粘贴。 */
    var oversize: Bool
    /** 可写回剪切板的负载。超限时为空。 */
    var representations: [CapturedRepresentation]
}

/**
 * 把剪切板快照整理成可入库的条目。
 *
 * 不访问系统剪切板，只消费已经读好的快照。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum CaptureBuilder {
    /**
     * 由快照生成一条采集结果。
     *
     * 没有文本、富文本、图片和文件时返回空。超限时仍返回条目，但负载为空。
     *
     * @param snapshot 已读取的剪切板快照
     * @param limits 单条大小上限
     * @return 可入库的条目；没有可记录内容时返回 nil
     */
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

    /**
     * 合并各项中的类型数据。
     *
     * 同一 UTI 保留先出现的数据。
     *
     * @param snapshot 剪切板快照
     * @return 以 UTI 为键的数据
     */
    private static func merged(_ snapshot: PasteboardSnapshot) -> [String: Data] {
        var values: [String: Data] = [:]
        for item in snapshot.items {
            for (key, data) in item.values where values[key] == nil {
                values[key] = data
            }
        }
        return values
    }

    /**
     * 合并各项中的全文摘要。
     *
     * @param snapshot 剪切板快照
     * @return 以 UTI 为键的全文哈希
     */
    private static func mergedDigests(_ snapshot: PasteboardSnapshot) -> [String: String] {
        var digests: [String: String] = [:]
        for item in snapshot.items {
            for (key, digest) in item.fullDigests where digests[key] == nil {
                digests[key] = digest
            }
        }
        return digests
    }

    /**
     * 合并各项中的原文字节数。
     *
     * @param snapshot 剪切板快照
     * @return 以 UTI 为键的字节数
     */
    private static func mergedCounts(_ snapshot: PasteboardSnapshot) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in snapshot.items {
            for (key, count) in item.fullByteCounts where counts[key] == nil {
                counts[key] = count
            }
        }
        return counts
    }

    /**
     * 提取可搜索的纯文本。
     *
     * 优先 UTF-8，其次 UTF-16，再次 URL。
     *
     * @param values 按 UTI 索引的数据
     * @return 纯文本；三种类型都没有时返回 nil
     */
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

    /**
     * 提取第一张图片及其像素尺寸。
     *
     * 优先级为 PNG、TIFF、JPEG。
     *
     * @param values 按 UTI 索引的数据
     * @return 图片字节和宽高；没有图片时返回 nil
     */
    private static func imagePayload(from values: [String: Data]) -> (data: Data, width: Int?, height: Int?)? {
        let data = values[PasteboardUTI.png] ?? values[PasteboardUTI.tiff] ?? values[PasteboardUTI.jpeg]
        guard let data, !data.isEmpty else { return nil }
        let size = ImageSizing.pixelSize(of: data)
        return (data, size?.width, size?.height)
    }

    /**
     * 收集文件指纹。
     *
     * 同时识别 file URL 和旧式文件名列表，按路径去重。读取不到属性时大小和时间记为 0。
     *
     * @param snapshot 剪切板快照
     * @return 去重后的文件指纹
     */
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

    /**
     * 生成列表和搜索用的展示文本。
     *
     * 有文件时只保留文件名。文本超限时截到预览长度。
     *
     * @param plain 纯文本
     * @param files 文件指纹
     * @param limits 预览长度上限
     * @param textOversize 文本是否超过单条上限
     * @return 可入库的展示文本
     */
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

    /**
     * 判定条目类型。
     *
     * 图片和文件同时存在时为混合。只有文件、只有图片、有富文本时依次对应文件、图片、富文本。
     *
     * @param hasRich 是否包含 RTF 或 HTML
     * @param hadImage 是否包含图片
     * @param files 文件指纹
     * @return 条目类型
     */
    private static func kindFor(hasRich: Bool, hadImage: Bool, files: [FileFingerprint]) -> ItemKind {
        let hasFiles = !files.isEmpty
        if hadImage && hasFiles { return .mixed }
        if hasFiles { return .file }
        if hadImage { return .image }
        if hasRich { return .rich }
        return .text
    }

    /**
     * 选择去重哈希。
     *
     * 超限图片和超限文本使用读取阶段对原文算出的摘要，避免只对预览哈希导致不同大文本并成一条。
     *
     * @param plain 纯文本
     * @param values 按 UTI 索引的数据
     * @param digests 超限类型的全文摘要
     * @param image 已解码的图片
     * @param files 文件指纹
     * @param imageOversize 图片是否超过单条上限
     * @return 内容哈希
     */
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

    /**
     * 计算用于容量统计的字节数。
     *
     * 优先使用超限时记下的原文字节数，其次是图片、文件大小合计和纯文本长度。
     *
     * @param plain 纯文本
     * @param image 图片数据
     * @param files 文件指纹
     * @param counts 超限类型的原文字节数
     * @return 字节数
     */
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

    /**
     * 组装可持久化的负载。
     *
     * 标记类型不入库。文件只保存路径列表。
     *
     * @param values 按 UTI 索引的数据
     * @param files 文件指纹
     * @return 按 UTI 排序的负载
     */
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

/**
 * 图片像素尺寸。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum ImageSizing {
    /**
     * 读取图片的像素宽高。
     *
     * @param data 图片原始数据
     * @return 宽和高；无法解码时返回 nil
     */
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}
