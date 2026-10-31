import AppKit
import CryptoKit
import Foundation

/**
 * 内容去重哈希。
 *
 * 文本先规范化再摘要，图片优先用像素数据，文件用路径、大小和修改时间。
 * 相同哈希在入库时合并为一条，并更新使用时间。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum ContentHash {
    /**
     * 规范化文本，供哈希和纯文本比较使用。
     *
     * 做 Unicode 规范化，并把 CR、CRLF 统一成 LF。
     *
     * @param text 原始文本
     * @return 规范化后的文本
     */
    static func normalizeText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /**
     * 计算文本哈希。
     *
     * @param text 原始文本，内部会先规范化
     * @return SHA-256 十六进制摘要
     */
    static func text(_ text: String) -> String {
        sha256(Data(normalizeText(text).utf8))
    }

    /**
     * 计算图片哈希。
     *
     * 能解码出单平面像素时使用像素字节；否则退回原始文件字节。
     *
     * @param data 图片原始数据
     * @return SHA-256 十六进制摘要
     */
    static func imageData(_ data: Data) -> String {
        guard let rep = NSBitmapImageRep(data: data),
              rep.numberOfPlanes <= 1,
              let pixels = rep.bitmapData else {
            return sha256(data)
        }
        let count = rep.bytesPerRow * max(rep.pixelsHigh, 0)
        guard count > 0 else { return sha256(data) }
        return sha256(Data(bytes: pixels, count: count))
    }

    /**
     * 计算文件列表哈希。
     *
     * 路径按字典序排列后，与文件大小、修改时间一起摘要。内容本身不参与哈希。
     *
     * @param entries 文件指纹
     * @return SHA-256 十六进制摘要
     */
    static func files(_ entries: [FileFingerprint]) -> String {
        let canonical = entries
            .sorted { $0.path < $1.path }
            .map { "\($0.path)|\($0.size)|\($0.modifiedAt)" }
            .joined(separator: "\n")
        return sha256(Data(canonical.utf8))
    }

    /**
     * 计算 SHA-256 十六进制摘要。
     *
     * @param data 待摘要的字节
     * @return 小写十六进制字符串
     */
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
struct FileFingerprint: Equatable {
    /** 文件绝对路径。 */
    var path: String
    /** 文件字节大小。 */
    var size: Int64
    /** 修改时间，单位为秒。 */
    var modifiedAt: Int64
}
