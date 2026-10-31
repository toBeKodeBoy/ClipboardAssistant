import Foundation

/**
 * 历史条目类型。
 *
 * 采集时根据剪切板里实际出现的负载判定，搜索和筛选都读取这个值。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum ItemKind: String, Codable, CaseIterable {
    /** 纯文本。 */
    case text
    /** 带 RTF 或 HTML 的富文本。 */
    case rich
    /** 图片。 */
    case image
    /** 文件引用。 */
    case file
    /** 图片和文件同时存在。 */
    case mixed

    /**
     * 类型的界面名称。
     *
     * @return 当前语言下的类型名称
     */
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

/**
 * 主面板的筛选条件。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum ItemFilter: String, CaseIterable, Identifiable {
    /** 不按类型过滤。 */
    case all
    /** 纯文本和富文本。 */
    case text
    /** 图片，以及带有图片尺寸的条目。 */
    case image
    /** 文件和混合条目。 */
    case file
    /** 已置顶条目。 */
    case pinned

    /** 筛选标识，与原始值相同。 */
    var id: String { rawValue }

    /**
     * 筛选项的界面名称。
     *
     * @return 当前语言下的筛选项名称
     */
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

/**
 * 历史列表的时间分组。
 *
 * 置顶固定在最上方，其余按最近使用时间分成刚刚、今天、昨天和更早。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum HistorySection: String, CaseIterable, Identifiable {
    /** 置顶。 */
    case pinned
    /** 最近 5 分钟内使用过。 */
    case justNow
    /** 今天使用过，且早于「刚刚」。 */
    case today
    /** 昨天使用过。 */
    case yesterday
    /** 更早使用过。 */
    case earlier

    /** 分组标识，与原始值相同。 */
    var id: String { rawValue }

    /**
     * 分组标题。
     *
     * @return 当前语言下的分组名称
     */
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
