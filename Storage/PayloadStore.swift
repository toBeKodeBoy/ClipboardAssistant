import Foundation
import ImageIO
import UniformTypeIdentifiers

final class PayloadStore {
    let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        try fileManager.createDirectory(at: root.appendingPathComponent("payloads"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
    }

    func write(itemID: String, uti: String, data: Data) throws -> String {
        let directory = root.appendingPathComponent("payloads").appendingPathComponent(itemID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = uti.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "data"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return "payloads/\(itemID)/\(name)"
    }

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

    func read(relativePath: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(relativePath))
    }

    func fileURL(relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func removeItem(id: String) {
        let payload = root.appendingPathComponent("payloads").appendingPathComponent(id, isDirectory: true)
        let thumb = root.appendingPathComponent("thumbs").appendingPathComponent("\(id).jpg")
        try? fileManager.removeItem(at: payload)
        try? fileManager.removeItem(at: thumb)
    }

    func removeAllPayloads() {
        let payloads = root.appendingPathComponent("payloads")
        let thumbs = root.appendingPathComponent("thumbs")
        try? fileManager.removeItem(at: payloads)
        try? fileManager.removeItem(at: thumbs)
        try? fileManager.createDirectory(at: payloads, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbs, withIntermediateDirectories: true)
    }
}
