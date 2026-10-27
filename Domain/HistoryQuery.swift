import Foundation

enum HistoryQuery {
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
