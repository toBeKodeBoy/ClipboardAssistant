import Foundation
import ImageIO
import UniformTypeIdentifiers

/**
 * 历史负载文件。
 *
 * 图片和原始类型数据按条目分目录存放。缩略图单独放在 thumbs。文件历史不在这里备份文件内容。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
final class PayloadStore {
    /** 应用支持目录，其下有 payloads 和 thumbs。 */
    let root: URL
    /** 读写文件使用的文件管理器。 */
    private let fileManager: FileManager

    /**
     * 确保负载目录和缩略图目录存在。
     *
     * @param root 应用支持目录
     * @param fileManager 文件管理器
     * @throws 创建目录失败时抛出
     */
    init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        try fileManager.createDirectory(at: root.appendingPathComponent("payloads"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
    }

    /**
     * 把一种类型的负载写到条目目录。
     *
     * @param itemID 条目标识
     * @param uti 剪切板类型，会编码进文件名
     * @param data 负载字节
     * @return 相对 root 的路径，供数据库记录
     * @throws 创建目录或写文件失败时抛出
     */
    func write(itemID: String, uti: String, data: Data) throws -> String {
        let directory = root.appendingPathComponent("payloads").appendingPathComponent(itemID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = uti.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "data"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return "payloads/\(itemID)/\(name)"
    }

    /**
     * 生成最长边 360 像素的 JPEG 缩略图。
     *
     * 解码失败时返回 nil，不影响条目本身入库。
     *
     * @param itemID 条目标识
     * @param imageData 原图字节
     * @return 相对 root 的缩略图路径；无法生成时返回 nil
     */
    func writeThumbnail(itemID: String, imageData: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let url = root.appendingPathComponent("thumbs").appendingPathComponent("\(itemID).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "thumbs/\(itemID).jpg"
    }

    /**
     * 按相对路径读取负载。
     *
     * @param relativePath 相对 root 的路径
     * @return 文件内容；文件不存在或读取失败时返回 nil
     */
    func read(relativePath: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(relativePath))
    }

    /**
     * 把相对路径解析成文件 URL。
     *
     * 不检查文件是否存在。
     *
     * @param relativePath 相对 root 的路径
     * @return 绝对文件 URL
     */
    func fileURL(relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /**
     * 删除一条历史的负载目录和缩略图。
     *
     * 应在数据库行删除成功后调用。文件已经不存在时忽略错误。
     *
     * @param id 条目标识
     */
    func removeItem(id: String) {
        let payload = root.appendingPathComponent("payloads").appendingPathComponent(id, isDirectory: true)
        let thumb = root.appendingPathComponent("thumbs").appendingPathComponent("\(id).jpg")
        try? fileManager.removeItem(at: payload)
        try? fileManager.removeItem(at: thumb)
    }

    /**
     * 删除全部负载和缩略图，并重建空目录。
     *
     * 由清空历史在删除数据库行之后调用。
     */
    func removeAllPayloads() {
        let payloads = root.appendingPathComponent("payloads")
        let thumbs = root.appendingPathComponent("thumbs")
        try? fileManager.removeItem(at: payloads)
        try? fileManager.removeItem(at: thumbs)
        try? fileManager.createDirectory(at: payloads, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbs, withIntermediateDirectories: true)
    }
}
