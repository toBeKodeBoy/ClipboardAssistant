import Foundation

/**
 * 历史保留策略。
 *
 * 按天数、条数和未置顶图片容量决定应删除的条目。置顶条目不参与这三项淘汰。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct RetentionPolicy: Equatable {
    /** 未置顶条数上限。nil 表示不限制条数。 */
    var maxCount: Int?
    /** 未置顶条目的最长保留时间，按创建时间计算。nil 表示永久保留。 */
    var maxAge: TimeInterval?
    /** 未置顶图片的总字节上限。 */
    var maxImageBytes: Int64

    /** 图片容量上限，固定为 200MB。 */
    static let imageCap: Int64 = 200 * 1024 * 1024

    /**
     * 找出因过期或条数超限应删除的条目。
     *
     * 先按创建时间淘汰过期的未置顶条目，再按最近使用时间从早到晚淘汰多余的未置顶条目。
     *
     * @param items 当前全部历史
     * @param now 判定时刻
     * @return 应删除的条目标识，顺序不稳定
     */
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

    /**
     * 找出超出图片容量上限的未置顶图片。
     *
     * 从最久未使用的图片开始删，直到剩余容量不超过上限。
     *
     * @param items 参与计算的历史，调用方应先去掉已判定删除的条目
     * @return 应删除的条目标识，按删除顺序排列
     */
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
