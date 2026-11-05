import AppKit
import Foundation

/**
 * 主面板和菜单栏共用的应用状态。
 *
 * 负责历史列表、搜索筛选、粘贴、删除撤销、暂停和热键注册。不直接读系统剪切板。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
@MainActor
final class AppModel: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var query = ""
    @Published var filter: ItemFilter = .all
    @Published var selectedID: String?
    @Published var banner: String?

    /**
     * 设置页清空失败时的提示。
     *
     * 历史变为空后清掉，避免另一边已经清空而这里仍显示失败。
     */
    @Published var clearAllError: String?
    @Published var confirmClearAll = false
    @Published var confirmPinnedDelete = false
    @Published var accessibilityTrusted = false

    /**
     * 辅助功能授权状态发生变化时调用。
     *
     * 参数是新的授权状态。菜单栏用来切换圆点和点击去向。
     */
    var onAccessibilityChange: ((Bool) -> Void)?

    var settings: AppSettings
    let store: HistoryStore
    private let pasteService = PasteService()
    private let monitor = CaptureMonitor()
    private var targetBundleID: String?
    private var undoItem: ClipboardItem?
    private var undoRepresentations: [CapturedRepresentation] = []
    private var deleteSession = ItemDeleteSession()

    /**
     * 打开置顶删除确认框时记下的条目标识。
     *
     * 确认按钮用它删除，不跟随确认框打开后的选中变化。
     */
    var pendingPinnedDeleteID: String? { deleteSession.pendingID }

    /**
     * 清空历史失败时，设置页和主面板共用的提示。
     */
    static let clearAllFailedMessage = L10n.text("清空失败", "Couldn't clear history")

    /**
     * 用已打开的存储和偏好创建模型。
     *
     * 不在这里开始采集，调用方在装配完面板后再调用 start。
     *
     * @param store 历史存储
     * @param settings 用户偏好
     */
    init(store: HistoryStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    /**
     * 启动采集、热键，并按保留策略清理一次历史。
     */
    func start() {
        reload()
        try? store.applyRetention(settings.retention)
        reload()
        monitor.onCaptured = { [weak self] captured, bundleID, name in
            Task { @MainActor in
                self?.ingest(captured, bundleID: bundleID, name: name)
            }
        }
        monitor.start(settings: settings)
        applyHotkey()
        refreshAccessibility()
        let itemCount = items.count
        let trusted = accessibilityTrusted
        AppLog.store.info("started items=\(itemCount) accessibility=\(trusted)")
    }

    /**
     * 从数据库重新加载历史。
     *
     * 查询失败时记录错误，并把界面列表清空。当前选中项不在结果里时改选筛选后的第一条。
     * 查询成功且历史为空时，清掉清空失败提示。查询失败时保留这条提示。
     */
    func reload() {
        do {
            items = try store.fetchAll()
            if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
                selectedID = visibleItems().first?.id
            }
            dismissClearAllFailureIfHistoryEmpty()
        } catch {
            AppLog.store.error("reload failed \(String(describing: error))")
            items = []
        }
    }

    /**
     * 历史已经为空时，清掉清空失败提示。
     *
     * 设置页和主面板都可以把历史清掉。失败提示留在另一边时，空列表不能再显示「清空失败」。
     */
    private func dismissClearAllFailureIfHistoryEmpty() {
        guard items.isEmpty else { return }
        clearAllError = nil
        if banner == Self.clearAllFailedMessage {
            banner = nil
        }
    }

    /**
     * 当前搜索和筛选下可见的条目。
     *
     * 顺序与 items 一致，置顶仍在前面。
     *
     * @return 可见条目
     */
    func visibleItems() -> [ClipboardItem] {
        items.filter { HistoryQuery.matches($0, query: query, filter: filter) }
    }

    /**
     * 把可见条目按置顶和时间分组。
     *
     * 空分组不返回。
     *
     * @return 分组标题和该组条目
     */
    func groupedVisible() -> [(HistorySection, [ClipboardItem])] {
        let visible = visibleItems()
        return HistorySection.allCases.compactMap { section in
            let rows = visible.filter { HistoryGrouping.section(for: $0) == section }
            return rows.isEmpty ? nil : (section, rows)
        }
    }

    /**
     * 记下当前前台应用，作为这次打开面板后的粘贴目标。
     *
     * 必须在面板成为关键窗口之前调用。
     */
    func rememberFrontApp() {
        targetBundleID = FrontmostApp.current().bundleID
    }

    /**
     * 复制或粘贴一条历史。
     *
     * 未指定条目时使用当前选中项。失败提示写入 banner，并由 onPasteFeedback 重新打开面板。
     *
     * @param mode 粘贴模式
     * @param itemID 条目标识，为空时用 selectedID
     */
    func paste(mode: PasteMode, itemID: String? = nil) {
        let id = itemID ?? selectedID
        guard let id, let item = items.first(where: { $0.id == id }) else { return }
        let representations = (try? store.representations(for: id)) ?? []
        pasteService.perform(
            item: item,
            representations: representations,
            directory: store.directory,
            mode: mode,
            targetBundleID: targetBundleID,
            behavior: settings.pasteBehavior,
            beginSelfWrite: { [weak self] hash, digests in
                self?.monitor.beginSelfWrite(hash: hash, digests: digests) ?? 0
            },
            finishSelfWrite: { [weak self] token, count in
                self?.monitor.finishSelfWrite(token: token, changeCount: count)
            },
            prepareForKeystroke: { [weak self] in
                self?.onPreparePaste?()
            },
            completion: { [weak self] outcome in
                Task { @MainActor in
                    self?.banner = outcome.message
                    if outcome.message != nil {
                        self?.onPasteFeedback?()
                    }
                }
            }
        )
    }

    /**
     * 删除当前选中条目。
     *
     * 置顶条目先打开确认框，并清掉底部旧提示。确认后由 deletePinned 删除打开时记下的那一条。
     * 普通条目删除后可在面板关闭前用 ⌘Z 撤销。
     */
    func deleteSelected() {
        let item = items.first { $0.id == selectedID }
        let request = deleteSession.request(selectedID: item?.id, isPinned: item?.pinned == true)
        if request.clearsBanner {
            banner = nil
        }
        switch request {
        case .ignored:
            return
        case .confirmPinned:
            confirmPinnedDelete = true
        case .deleteNow(let id):
            if confirmPinnedDelete {
                confirmPinnedDelete = false
            }
            guard let item = items.first(where: { $0.id == id }) else { return }
            delete(id: id, item: item)
        }
    }

    /**
     * 删除打开确认框时记下的置顶条目。
     *
     * explicitID 是确认按钮创建时带上的那条，避免确认框先关掉把会话清掉。
     * 为空时用会话里记下的 id。之后选中项变了也不改删哪一条。
     * 条目已经不在或不再置顶时不删。
     *
     * @param explicitID 确认按钮捕获的条目标识
     */
    func deletePinned(id explicitID: String?) {
        let stored = deleteSession.confirm()
        if confirmPinnedDelete {
            confirmPinnedDelete = false
        }
        let id = explicitID ?? stored
        guard let id, let item = items.first(where: { $0.id == id }), item.pinned else { return }
        delete(id: id, item: item)
    }

    /**
     * 取消尚未确认的置顶删除。条目保留。
     */
    func cancelPinnedDelete() {
        deleteSession.cancel()
        if confirmPinnedDelete {
            confirmPinnedDelete = false
        }
    }

    /**
     * 同步确认框开关。关掉时丢弃记下的条目，避免之后误删。
     *
     * 值没有变化时不再写回，防止确认框关闭和模型互相触发。
     *
     * @param presented 确认框是否显示
     */
    func setPinnedDeletePresented(_ presented: Bool) {
        guard presented != confirmPinnedDelete else {
            if !presented {
                deleteSession.cancel()
            }
            return
        }
        confirmPinnedDelete = presented
        if !presented {
            deleteSession.cancel()
        }
    }

    /**
     * 撤销最近一次单条删除。
     *
     * 没有可撤销的条目时什么也不做。清空全部后撤销栈会被丢掉。
     */
    func undoDelete() {
        guard let item = undoItem else { return }
        undoItem = nil
        banner = L10n.text("已撤销删除", "Delete undone")
        reinsert(item)
    }

    /**
     * 切换置顶状态。
     *
     * @param id 条目标识，为空时用当前选中项
     */
    func togglePin(id: String? = nil) {
        guard let id = id ?? selectedID else { return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? store.setPinned(id: id, pinned: !item.pinned)
        reload()
    }

    /**
     * 清空全部历史，包括置顶。
     *
     * 失败时抛错，调用方必须提示，不能把列表显示成已清空。
     *
     * @throws 存储清空失败时抛出
     */
    func clearAll() throws {
        try store.clearAll()
        undoItem = nil
        undoRepresentations = []
        reload()
        AppLog.store.info("cleared history")
    }

    /**
     * 从设置页清空全部历史。
     *
     * 失败时显示「清空失败」，不刷新列表。成功后的空列表会清掉这条提示。
     */
    func clearAllFromSettings() {
        do {
            try clearAll()
        } catch {
            clearAllError = Self.clearAllFailedMessage
        }
    }

    /**
     * 从主面板清空全部历史。
     *
     * 失败时在面板底部显示「清空失败」，不刷新列表。成功后的空列表会清掉同一句提示。
     */
    func clearAllFromPanel() {
        do {
            try clearAll()
        } catch {
            banner = Self.clearAllFailedMessage
        }
    }

    /**
     * 按当前偏好重新注册全局热键。
     *
     * 打开主面板始终注册。暂停热键没有文案时注销；和主面板组合相同，或系统拒绝时标红。
     * 系统拒绝时这一组原来的热键保持有效。
     */
    func applyHotkey() {
        let panelOK = hotkeys.register(
            id: .panel,
            keyCode: UInt32(settings.hotkeyCode),
            modifiers: UInt32(settings.hotkeyModifiers)
        ) { [weak self] in
            Task { @MainActor in
                self?.onHotkey?()
            }
        }
        settings.hotkeyConflict = !panelOK
        if panelOK {
            AppLog.store.info("hotkey registered panel \(self.settings.hotkeyDisplay)")
        } else {
            AppLog.store.error("panel hotkey registration failed")
        }
        switch HotkeyPlan.pause(
            code: settings.pauseHotkeyCode,
            modifiers: settings.pauseHotkeyModifiers,
            display: settings.pauseHotkeyDisplay,
            panelCode: settings.hotkeyCode,
            panelModifiers: settings.hotkeyModifiers
        ) {
        case .skip:
            hotkeys.unregister(id: .pause)
            settings.pauseHotkeyConflict = false
        case .conflict:
            hotkeys.unregister(id: .pause)
            settings.pauseHotkeyConflict = true
            AppLog.store.error("pause hotkey matches panel hotkey")
        case .register(let keyCode, let modifiers):
            let pauseOK = hotkeys.register(id: .pause, keyCode: keyCode, modifiers: modifiers) { [weak self] in
                Task { @MainActor in
                    self?.togglePause()
                }
            }
            settings.pauseHotkeyConflict = !pauseOK
            if pauseOK {
                AppLog.store.info("hotkey registered pause \(self.settings.pauseHotkeyDisplay)")
            } else {
                AppLog.store.error("pause hotkey registration failed")
            }
        }
    }

    /**
     * 清除暂停热键并注销这一组。
     *
     * 打开主面板的热键保持不变。
     */
    func clearPauseHotkey() {
        settings.pauseHotkeyCode = 0
        settings.pauseHotkeyModifiers = 0
        settings.pauseHotkeyDisplay = ""
        settings.pauseHotkeyConflict = false
        applyHotkey()
    }

    /** 全局热键登记。测试可换成不向系统注册的实现。 */
    var hotkeys: GlobalHotkeys = HotkeyCenter.shared
    /** 全局热键按下时调用，由状态栏控制器打开或关闭面板。 */
    var onHotkey: (() -> Void)?
    /** 发送 ⌘V 之前调用，由面板控制器先关掉面板。 */
    var onPreparePaste: (() -> Void)?
    /** 自动粘贴失败时调用，由面板控制器重新打开并保留提示。 */
    var onPasteFeedback: (() -> Void)?

    /**
     * 刷新辅助功能授权状态，供菜单栏圆点和空状态提示使用。
     *
     * 状态有变化时通知 onAccessibilityChange。没有变化时不重复通知。
     */
    func refreshAccessibility() {
        let trusted = AccessibilityClient.isTrusted()
        guard trusted != accessibilityTrusted else { return }
        accessibilityTrusted = trusted
        onAccessibilityChange?(trusted)
    }

    /**
     * 弹出辅助功能授权提示，并打开系统设置里的对应页面。
     *
     * 权限说明、空历史和关于页共用这一处。返回后立刻刷新授权状态。
     */
    func openAccessibilitySettings() {
        _ = AccessibilityClient.promptAndOpenSettings()
        refreshAccessibility()
    }

    /**
     * 按暂停时长开始暂停，或立即恢复。
     *
     * 已经处于暂停时一律恢复。否则按 pauseChoice 设为手动、15 分钟或 1 小时。结束后重画菜单栏图标。
     */
    func togglePause() {
        settings.refreshPause(notify: false)
        if settings.isPaused {
            settings.manuallyPaused = false
            settings.pauseUntil = nil
        } else {
            switch settings.pauseChoice {
            case .manual:
                settings.manuallyPaused = true
            case .quarterHour:
                settings.pauseUntil = Date().addingTimeInterval(15 * 60)
            case .oneHour:
                settings.pauseUntil = Date().addingTimeInterval(60 * 60)
            }
        }
        let paused = settings.isPaused
        AppLog.capture.info("pause changed paused=\(paused)")
        settings.onPauseStateChange?()
    }

    /**
     * 在访达中显示条目引用的文件。
     *
     * 文件已移动或删除时设置失败提示，不改变剪切板。
     *
     * @param explicitID 条目标识，为空时用当前选中项
     */
    func revealInFinder(id explicitID: String? = nil) {
        guard let id = explicitID ?? selectedID else { return }
        let representations = (try? store.representations(for: id)) ?? []
        let paths = representations
            .filter { $0.uti == PasteboardUTI.fileURL }
            .compactMap(\.inlineValue)
            .flatMap { $0.split(separator: "\n").map(String.init) }
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            banner = L10n.text("无法在访达中显示", "Can't show in Finder")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /**
     * 返回条目缩略图地址。
     *
     * @param id 条目标识
     * @return 缩略图 URL；没有缩略图时返回 nil
     */
    func thumbnailURL(for id: String) -> URL? {
        store.thumbnailURL(for: id)
    }

    /**
     * 把采集结果入库并执行保留策略。
     *
     * 写入失败只记日志，不把列表清空。
     *
     * @param captured 采集结果
     * @param bundleID 来源应用标识
     * @param name 来源应用显示名
     */
    private func ingest(_ captured: CapturedClipboard, bundleID: String?, name: String) {
        do {
            _ = try store.insertOrTouch(captured, sourceBundleID: bundleID, sourceName: name)
            try store.applyRetention(settings.retention)
            reload()
        } catch {
            AppLog.store.error("insert failed \(String(describing: error))")
        }
    }

    /**
     * 删除条目并留下一次撤销。
     *
     * 数据库删除失败时保留原列表和提示，不记录撤销。
     *
     * @param id 条目标识
     * @param item 删除前的条目，供撤销时写回
     */
    private func delete(id: String, item: ClipboardItem) {
        let representations = (try? store.loadRepresentations(for: id)) ?? []
        do {
            try store.delete(id: id)
        } catch {
            banner = L10n.text("删除失败", "Couldn't delete")
            AppLog.store.error("delete failed \(String(describing: error))")
            return
        }
        undoRepresentations = representations
        undoItem = item
        banner = L10n.text("已删除，⌘Z 撤销", "Deleted. Press ⌘Z to undo.")
        reload()
    }

    /**
     * 把刚删除的条目按原哈希写回。
     *
     * 使用删除前的最近使用时间，避免撤销后被当成一次新的复制。
     *
     * @param item 被撤销的条目
     */
    private func reinsert(_ item: ClipboardItem) {
        let captured = CapturedClipboard(
            kind: item.kind,
            plainText: item.plainText,
            contentHash: item.contentHash,
            byteSize: item.byteSize,
            imageWidth: item.imageWidth,
            imageHeight: item.imageHeight,
            oversize: item.payloadOversize,
            representations: undoRepresentations
        )
        undoRepresentations = []
        _ = try? store.insertOrTouch(captured, sourceBundleID: item.sourceBundleID, sourceName: item.sourceName, now: item.lastUsedAt)
        reload()
    }
}
