import Foundation

/**
 * 一条剪切板历史。
 *
 * 只描述已入库的元数据和展示摘要，不读写系统剪切板。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct ClipboardItem: Identifiable, Equatable {
    /** 条目标识。 */
    var id: String
    /** 内容类型。 */
    var kind: ItemKind
    /** 供搜索和预览的纯文本。文件条目里是按行排列的文件名。 */
    var plainText: String
    /** 去重哈希。相同哈希再次复制时只更新原条目。 */
    var contentHash: String
    /** 复制发生时前台应用的 bundle id。没有时为空。 */
    var sourceBundleID: String?
    /** 来源应用显示名。通用剪贴板同步来的内容使用固定文案。 */
    var sourceName: String
    /** 首次入库时间。保留天数按这个时间计算。 */
    var createdAt: Date
    /** 最近一次复制或使用的时间。条数淘汰按这个时间从早到晚删除。 */
    var lastUsedAt: Date
    /** 是否置顶。置顶不参与条数、天数和图片容量淘汰。 */
    var pinned: Bool
    /** 置顶顺序。未置顶时为空，数值小的排在前面。 */
    var pinOrder: Int?
    /** 原文或图片的字节大小。超限条目记录的是原文大小。 */
    var byteSize: Int
    /** 图片像素宽度。非图片为空。 */
    var imageWidth: Int?
    /** 图片像素高度。非图片为空。 */
    var imageHeight: Int?
    /** 原文超过单条上限，只保留了预览，不能从这条恢复粘贴。 */
    var payloadOversize: Bool

    /**
     * 列表标题。
     *
     * 多个文件显示「首个文件名等 N 个文件」。文本取第一行，空白内容使用占位文案。
     *
     * @return 单行标题
     */
    var title: String {
        let names = fileNames
        if kind == .file || (kind == .mixed && names.count > 1) {
            if names.count > 1 {
                return L10n.text("\(names[0]) 等 \(names.count) 个文件", "\(names[0]) and \(names.count) files")
            }
            if let first = names.first, !first.isEmpty { return first }
        }
        let line = plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? plainText
        if line.isEmpty { return L10n.text("（空内容）", "(Empty)") }
        return line
    }

    /**
     * 从纯文本里拆出的文件名。
     *
     * 文件条目的 plainText 按行保存文件名。
     *
     * @return 去掉空白行后的文件名
     */
    var fileNames: [String] {
        plainText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /**
     * 列表副标题。
     *
     * 置顶条目显示「置顶」，其余显示来源应用和相对时间。
     *
     * @return 「来源 · 时间」形式的副标题
     */
    var subtitle: String {
        let time = pinned ? L10n.text("置顶", "Pinned") : RelativeTime.string(from: lastUsedAt)
        return "\(sourceName) · \(time)"
    }
}

/**
 * 相对时间文案。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum RelativeTime {
    /**
     * 把时间格式化成相对当前时刻的短文案。
     *
     * @param date 待显示的时间
     * @param now 对照时刻，默认是当前时间
     * @return 本地化的相对时间
     */
    static func string(from date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/**
 * 历史列表分组。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum HistoryGrouping {
    /**
     * 计算条目所属分组。
     *
     * 置顶优先。未置顶时，5 分钟内为刚刚，同一天为今天，前一天为昨天，其余为更早。
     *
     * @param item 历史条目
     * @param now 对照时刻
     * @param calendar 用于判断同一天的日历
     * @return 列表分组
     */
    static func section(for item: ClipboardItem, now: Date = Date(), calendar: Calendar = .current) -> HistorySection {
        if item.pinned { return .pinned }
        if now.timeIntervalSince(item.lastUsedAt) < 5 * 60 { return .justNow }
        if calendar.isDate(item.lastUsedAt, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(item.lastUsedAt, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .earlier
    }
}
