import Foundation

/**
 * 历史搜索。
 *
 * 在纯文本、来源应用名和标题上做包含匹配。英文不区分大小写，中文按子串匹配。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum HistoryQuery {
    /**
     * 判断条目是否同时满足筛选和搜索。
     *
     * 搜索词去掉首尾空白后为空时，只按筛选条件保留。
     *
     * @param item 待判断的历史条目
     * @param query 搜索词
     * @param filter 类型或置顶筛选
     * @return 命中时返回 true
     */
    static func matches(_ item: ClipboardItem, query: String, filter: ItemFilter) -> Bool {
        if !passes(filter, item: item) { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let haystack = [item.plainText, item.sourceName, item.title]
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let needle = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return haystack.contains(needle)
    }

    /**
     * 判断条目是否属于当前筛选。
     *
     * @param filter 筛选条件
     * @param item 待判断的历史条目
     * @return 属于该筛选时返回 true
     */
    private static func passes(_ filter: ItemFilter, item: ClipboardItem) -> Bool {
        switch filter {
        case .all:
            return true
        case .text:
            return item.kind == .text || item.kind == .rich
        case .image:
            return item.kind == .image || item.imageWidth != nil
        case .file:
            return item.kind == .file || item.kind == .mixed
        case .pinned:
            return item.pinned
        }
    }
}
