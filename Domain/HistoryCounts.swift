import Foundation

struct HistoryCounts: Equatable {
    var total: Int
    var pinned: Int
    var unpinned: Int
    var byKind: [ItemKind: Int]

    func count(for kind: ItemKind) -> Int {
        byKind[kind] ?? 0
    }

    func panelSummary(maxCount: Int) -> String {
        let limit = maxCount == 0 ? L10n.text("不限制", "No limit") : "\(maxCount)"
        return L10n.text(
            "\(total) 条 · 置顶 \(pinned) · 未置顶上限 \(limit)",
            "\(total) items · \(pinned) pinned · unpinned limit \(limit)"
        )
    }

    var diagnosticCounts: [String: Int] {
        var counts: [String: Int] = [
            "total": total,
            "pinned": pinned,
            "unpinned": unpinned
        ]
        for kind in ItemKind.allCases {
            counts[kind.rawValue] = count(for: kind)
        }
        return counts
    }

    static func tally(_ items: [ClipboardItem]) -> HistoryCounts {
        var byKind: [ItemKind: Int] = [:]
        var pinned = 0
        for item in items {
            byKind[item.kind, default: 0] += 1
            if item.pinned { pinned += 1 }
        }
        return HistoryCounts(
            total: items.count,
            pinned: pinned,
            unpinned: items.count - pinned,
            byKind: byKind
        )
    }
}
