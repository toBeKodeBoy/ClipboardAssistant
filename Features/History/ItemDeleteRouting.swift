import Foundation

/**
 * 单条删除走到哪一步。
 *
 * 置顶条目必须先弹出确认框。不能只在面板底部写一句提示。
 */
enum ItemDeleteStep: Equatable {
    /// 没有选中条目。
    case ignored
    /// 未置顶，立刻删除。
    case deleteImmediately
    /// 已置顶，先弹出确认框，不删除。
    case presentPinnedConfirmation
}

/**
 * 单条删除和确认框打开时的按键去向。
 *
 * 键盘 ⌫ 与右键「删除」共用这里的结论。确认框已经打开时，面板把按键交回去，
 * 回车和 Esc 才能作用在确认框上。
 */
enum ItemDeleteRouting {
    /**
     * 决定 ⌫ 对当前选中条做什么。
     *
     * @param hasSelection 是否有选中条目
     * @param isPinned 选中条目是否置顶。没有选中时忽略
     * @return 删除步骤
     */
    static func step(hasSelection: Bool, isPinned: Bool) -> ItemDeleteStep {
        guard hasSelection else { return .ignored }
        return isPinned ? .presentPinnedConfirmation : .deleteImmediately
    }

    /**
     * 清空或删除置顶的确认框打开时，按键交给确认框。
     *
     * @param confirmClearAll 清空确认框是否打开
     * @param confirmPinnedDelete 删除置顶确认框是否打开
     * @return 应把按键交出去时返回 true
     */
    static func yieldsKeysToConfirmation(confirmClearAll: Bool, confirmPinnedDelete: Bool) -> Bool {
        confirmClearAll || confirmPinnedDelete
    }
}
