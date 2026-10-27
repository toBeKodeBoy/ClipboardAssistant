import Foundation

struct ClipboardItem: Identifiable, Equatable {
    var id: String
    var kind: ItemKind
    var plainText: String
    var contentHash: String
    var sourceBundleID: String?
    var sourceName: String
    var createdAt: Date
    var lastUsedAt: Date
    var pinned: Bool
    var pinOrder: Int?
    var byteSize: Int
    var imageWidth: Int?
    var imageHeight: Int?
    var payloadOversize: Bool

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

    var fileNames: [String] {
        plainText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var subtitle: String {
        let time = pinned ? L10n.text("置顶", "Pinned") : RelativeTime.string(from: lastUsedAt)
        return "\(sourceName) · \(time)"
    }
}

enum RelativeTime {
    static func string(from date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum HistoryGrouping {
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
