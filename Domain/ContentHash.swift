import AppKit
import CryptoKit
import Foundation

enum ContentHash {
    static func normalizeText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func text(_ text: String) -> String {
        sha256(Data(normalizeText(text).utf8))
    }

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

    static func files(_ entries: [FileFingerprint]) -> String {
        let canonical = entries
            .sorted { $0.path < $1.path }
            .map { "\($0.path)|\($0.size)|\($0.modifiedAt)" }
            .joined(separator: "\n")
        return sha256(Data(canonical.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct FileFingerprint: Equatable {
    var path: String
    var size: Int64
    var modifiedAt: Int64
}
