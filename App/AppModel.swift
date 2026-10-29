import AppKit
import Foundation

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

    init(store: HistoryStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

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

    func visibleItems() -> [ClipboardItem] {
        items.filter { HistoryQuery.matches($0, query: query, filter: filter) }
    }

    func groupedVisible() -> [(HistorySection, [ClipboardItem])] {
        let visible = visibleItems()
        return HistorySection.allCases.compactMap { section in
            let rows = visible.filter { HistoryGrouping.section(for: $0) == section }
            return rows.isEmpty ? nil : (section, rows)
        }
    }

    func rememberFrontApp() {
        targetBundleID = FrontmostApp.current().bundleID
    }

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

    func deleteSelected() {
        guard let id = selectedID, let item = items.first(where: { $0.id == id }) else { return }
        if item.pinned {
            banner = L10n.text("置顶条目需要确认后再删除", "Pinned items need confirmation")
            return
        }
        delete(id: id, item: item)
    }

    func deletePinnedConfirmed() {
        guard let id = selectedID, let item = items.first(where: { $0.id == id }), item.pinned else { return }
        delete(id: id, item: item)
    }

    func undoDelete() {
        guard let item = undoItem else { return }
        undoItem = nil
        banner = L10n.text("已撤销删除", "Delete undone")
        reinsert(item)
    }

    func togglePin(id: String? = nil) {
        guard let id = id ?? selectedID else { return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? store.setPinned(id: id, pinned: !item.pinned)
        reload()
    }

    func clearAll() throws {
        try store.clearAll()
        undoItem = nil
        undoRepresentations = []
        reload()
        AppLog.store.info("cleared history")
    }

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

    var onHotkey: (() -> Void)?
    var onPreparePaste: (() -> Void)?
    var onPasteFeedback: (() -> Void)?

    func refreshAccessibility() {
        accessibilityTrusted = AccessibilityClient.isTrusted()
    }

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

    func thumbnailURL(for id: String) -> URL? {
        store.thumbnailURL(for: id)
    }

    private func ingest(_ captured: CapturedClipboard, bundleID: String?, name: String) {
        do {
            _ = try store.insertOrTouch(captured, sourceBundleID: bundleID, sourceName: name)
            try store.applyRetention(settings.retention)
            reload()
        } catch {
            AppLog.store.error("insert failed \(String(describing: error))")
        }
    }

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
