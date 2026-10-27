import Foundation

enum ItemKind: String, Codable, CaseIterable {
    case text
    case rich
    case image
    case file
    case mixed

    var title: String {
        switch self {
        case .text: L10n.text("文本", "Text")
        case .rich: L10n.text("富文本", "Rich text")
        case .image: L10n.text("图片", "Images")
        case .file: L10n.text("文件", "Files")
        case .mixed: L10n.text("混合", "Mixed")
        }
    }
}

enum ItemFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case file
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .text: L10n.text("文本", "Text")
        case .image: L10n.text("图片", "Images")
        case .file: L10n.text("文件", "Files")
        case .pinned: L10n.text("置顶", "Pinned")
        }
    }
}

enum HistorySection: String, CaseIterable, Identifiable {
    case pinned
    case justNow
    case today
    case yesterday
    case earlier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: L10n.text("置顶", "Pinned")
        case .justNow: L10n.text("刚刚", "Just now")
        case .today: L10n.text("今天", "Today")
        case .yesterday: L10n.text("昨天", "Yesterday")
        case .earlier: L10n.text("更早", "Earlier")
        }
    }
}
