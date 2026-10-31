import Foundation

/**
 * 历史条数统计。
 *
 * 供面板底部摘要和关于页诊断使用，不包含剪切板正文。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct HistoryCounts: Equatable {
    /** 全部条数，含置顶。 */
    var total: Int
    /** 置顶条数。 */
    var pinned: Int
    /** 未置顶条数。 */
    var unpinned: Int
    /** 各类型条数。 */
    var byKind: [ItemKind: Int]

    /**
     * 读取某一类型的条数。
     *
     * @param kind 条目类型
     * @return 该类型的条数，没有时为 0
     */
    func count(for kind: ItemKind) -> Int {
        byKind[kind] ?? 0
    }

    /**
     * 生成面板底部的条数摘要。
     *
     * @param maxCount 未置顶条数上限，0 表示不限制
     * @return 当前语言下的摘要文案
     */
    func panelSummary(maxCount: Int) -> String {
        let limit = maxCount == 0 ? L10n.text("不限制", "No limit") : "\(maxCount)"
        return L10n.text(
            "\(total) 条 · 置顶 \(pinned) · 未置顶上限 \(limit)",
            "\(total) items · \(pinned) pinned · unpinned limit \(limit)"
        )
    }

    /**
     * 导出诊断用的条数。
     *
     * 只含数量，不含正文、来源名称或负载路径。
     *
     * @return 以 total、pinned、unpinned 和类型原始值为键的计数
     */
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

    /**
     * 统计一组历史条目。
     *
     * @param items 待统计的条目
     * @return 汇总后的条数
     */
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
