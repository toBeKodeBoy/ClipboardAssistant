import Foundation

struct RetentionPolicy: Equatable {
    var maxCount: Int?
    var maxAge: TimeInterval?
    var maxImageBytes: Int64

    static let imageCap: Int64 = 200 * 1024 * 1024

    func expiredAndOverflowIDs(in items: [ClipboardItem], now: Date) -> [String] {
        var doomed = Set<String>()
        if let maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            for item in items where !item.pinned && item.createdAt < cutoff {
                doomed.insert(item.id)
            }
        }
        if let maxCount {
            let unpinned = items.filter { !doomed.contains($0.id) && !$0.pinned }
            let overflow = unpinned.count - maxCount
            if overflow > 0 {
                let victims = unpinned
                    .sorted { $0.lastUsedAt < $1.lastUsedAt }
                    .prefix(overflow)
                for item in victims {
                    doomed.insert(item.id)
                }
            }
        }
        return Array(doomed)
    }

    func imageOverflowIDs(in items: [ClipboardItem]) -> [String] {
        var candidates = items
            .filter { ($0.kind == .image || $0.imageWidth != nil) && !$0.pinned }
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
        var total = candidates.reduce(Int64(0)) { $0 + Int64($1.byteSize) }
        var doomed: [String] = []
        while total > maxImageBytes, !candidates.isEmpty {
            let oldest = candidates.removeFirst()
            doomed.append(oldest.id)
            total -= Int64(oldest.byteSize)
        }
        return doomed
    }
}
