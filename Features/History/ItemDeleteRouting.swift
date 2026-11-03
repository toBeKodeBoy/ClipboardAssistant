import Foundation

/**
 * 单条删除的下一步。
 *
 * 置顶条目要弹出确认框，并清掉底部旧提示。未置顶直接删除，不动已有提示。
 */
enum ItemDeleteRequest: Equatable {
    /// 没有选中条目。
    case ignored
    /// 未置顶，立刻删除这一条。
    case deleteNow(id: String)
    /// 已置顶，先弹出确认框。id 是打开确认框时的那一条。
    case confirmPinned(id: String)

    /**
     * 这一步是否要清掉底部提示。
     *
     * 只有弹出置顶确认框时返回 true，避免旧提示和确认框叠在一起。
     */
    var clearsBanner: Bool {
        if case .confirmPinned = self { return true }
        return false
    }
}

/**
 * 一次置顶删除确认。
 *
 * 打开确认框时记下条目标识。之后选中项变了，确认仍然删除这一条。
 */
struct ItemDeleteSession: Equatable {
    private(set) var confirmationPresented = false
    private(set) var pendingID: String?

    /**
     * 决定当前选中条怎么删。
     *
     * @param selectedID 当前选中条。为空表示没有选中
     * @param isPinned 选中条是否置顶
     * @return 删除请求
     */
    mutating func request(selectedID: String?, isPinned: Bool) -> ItemDeleteRequest {
        guard let selectedID else { return .ignored }
        if isPinned {
            pendingID = selectedID
            confirmationPresented = true
            return .confirmPinned(id: selectedID)
        }
        pendingID = nil
        confirmationPresented = false
        return .deleteNow(id: selectedID)
    }

    /**
     * 确认删除，并关掉这次确认。
     *
     * @return 打开确认框时记下的条目标识。没有待确认的条目时返回空
     */
    mutating func confirm() -> String? {
        let id = pendingID
        cancel()
        return id
    }

    /**
     * 取消确认。之后再确认不会删除。
     */
    mutating func cancel() {
        pendingID = nil
        confirmationPresented = false
    }
}

/**
 * 确认框打开时的按键去向。
 *
 * 清空或删除置顶的确认框已经打开时，面板把按键交回去，回车和 Esc 才能作用在确认框上。
 */
enum ItemDeleteRouting {
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
