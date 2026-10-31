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
    @Published var confirmClearAll = false
    @Published var accessibilityTrusted = false

    var settings: AppSettings
    let store: HistoryStore
    private let pasteService = PasteService()
    private let monitor = CaptureMonitor()
    private var targetBundleID: String?
    private var undoItem: ClipboardItem?
    private var undoRepresentations: [CapturedRepresentation] = []

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
     */
    func reload() {
        do {
            items = try store.fetchAll()
            if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
                selectedID = visibleItems().first?.id
            }
        } catch {
            AppLog.store.error("reload failed \(String(describing: error))")
            items = []
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
            noteChangeCount: { [weak self] count in
                self?.monitor.ignoreChangeCount(count)
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
     * 置顶条目不直接删除，只提示需要确认。普通条目删除后可在面板关闭前用 ⌘Z 撤销。
     */
    func deleteSelected() {
        guard let id = selectedID, let item = items.first(where: { $0.id == id }) else { return }
        if item.pinned {
            banner = L10n.text("置顶条目需要确认后再删除", "Pinned items need confirmation")
            return
        }
        delete(id: id, item: item)
    }

    /**
     * 确认后删除当前置顶条目。
     */
    func deletePinnedConfirmed() {
        guard let id = selectedID, let item = items.first(where: { $0.id == id }), item.pinned else { return }
        delete(id: id, item: item)
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
     * 按当前偏好重新注册全局热键。
     *
     * 注册失败时把 hotkeyConflict 设为 true，供设置页标红。
     */
    func applyHotkey() {
        let ok = HotkeyCenter.shared.register(
            keyCode: UInt32(settings.hotkeyCode),
            modifiers: UInt32(settings.hotkeyModifiers)
        )
        settings.hotkeyConflict = !ok
        if ok {
            AppLog.store.info("hotkey registered \(self.settings.hotkeyDisplay)")
        } else {
            AppLog.store.error("hotkey registration failed")
        }
        HotkeyCenter.shared.onPressed = { [weak self] in
            Task { @MainActor in
                self?.onHotkey?()
            }
        }
    }

    /** 全局热键按下时调用，由状态栏控制器打开或关闭面板。 */
    var onHotkey: (() -> Void)?
    /** 发送 ⌘V 之前调用，由面板控制器先关掉面板。 */
    var onPreparePaste: (() -> Void)?
    /** 自动粘贴失败时调用，由面板控制器重新打开并保留提示。 */
    var onPasteFeedback: (() -> Void)?

    /**
     * 刷新辅助功能授权状态，供菜单栏圆点和空状态提示使用。
     */
    func refreshAccessibility() {
        accessibilityTrusted = AccessibilityClient.isTrusted()
    }

    /**
     * 按暂停时长开始暂停，或立即恢复。
     *
     * 已经处于暂停时一律恢复。否则按 pauseChoice 设为手动、15 分钟或 1 小时。
     */
    func togglePause() {
        settings.refreshPause()
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
