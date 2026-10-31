import AppKit
import Carbon
import SwiftUI

/**
 * 主面板窗口。
 *
 * 使用 nonactivatingPanel，呼出时不抢走原应用焦点。打开时记下前台应用；关闭时不改剪切板。
 * 全局热键调用方传入屏幕中心，菜单打开则使用「面板位置」设置。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: NSPanel
    private var keyMonitor: Any?
    private var outsideMonitor: Any?

    /**
     * 创建浮动主面板，并接上粘贴前关闭、失败后重新打开的回调。
     *
     * @param model 面板绑定的应用状态
     */
    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: model.settings.panelWidth, height: model.settings.panelHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = L10n.text("剪切板助手", "Clipboard Assistant")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 420, height: 360)
        panel.contentViewController = NSHostingController(rootView: HistoryPanelView().environmentObject(model))
        panel.appearance = model.settings.appearance.nsAppearance
        model.onPreparePaste = { [weak self] in
            self?.closePanel()
        }
        model.onPasteFeedback = { [weak self] in
            self?.showFeedback()
        }
    }

    /**
     * 已显示时关闭，未显示时按指定位置打开。
     *
     * @param placement 本次打开位置。为空时使用设置里的面板位置
     */
    func toggle(placement: PanelPlacement? = nil) {
        if panel.isVisible {
            closePanel()
        } else {
            show(placement: placement)
        }
    }

    /**
     * 显示主面板。
     *
     * 默认先记下前台应用并清掉上一次提示。粘贴失败后重新打开时两者都跳过，以保留提示和原目标。
     *
     * @param rememberingFrontApp 是否把当前前台应用记为粘贴目标
     * @param clearingBanner 是否清掉底部提示
     * @param placement 本次位置。为空时使用设置
     */
    func show(rememberingFrontApp: Bool = true, clearingBanner: Bool = true, placement: PanelPlacement? = nil) {
        if rememberingFrontApp {
            model.rememberFrontApp()
        }
        model.refreshAccessibility()
        if clearingBanner {
            model.banner = nil
        }
        panel.appearance = model.settings.appearance.nsAppearance
        var frame = panel.frame
        frame.size = NSSize(width: model.settings.panelWidth, height: model.settings.panelHeight)
        frame.origin = origin(for: frame.size, placement: placement)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        installOutsideMonitor()
    }

    /**
     * 粘贴失败后重新打开面板，保留失败提示和原来的粘贴目标。
     */
    func showFeedback() {
        guard !panel.isVisible else { return }
        show(rememberingFrontApp: false, clearingBanner: false)
    }

    /**
     * 关闭面板。
     *
     * 取消尚未确认的清空，记下当前尺寸，并卸掉按键和面板外点击监听。不修改剪切板。
     */
    func closePanel() {
        model.confirmClearAll = false
        model.settings.panelWidth = panel.frame.width
        model.settings.panelHeight = panel.frame.height
        panel.orderOut(nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
    }

    /**
     * 窗口即将关闭时走同一套关闭逻辑。
     *
     * @param notification 窗口关闭通知
     */
    func windowWillClose(_ notification: Notification) {
        closePanel()
    }

    /**
     * 计算面板原点，并把它限制在鼠标所在屏幕的可见区域内。
     *
     * center 放在该屏幕正中，其余放在指针附近。
     *
     * @param size 面板尺寸
     * @param placement 位置模式。为空时使用设置
     * @return 左下角坐标
     */
    private func origin(for size: NSSize, placement: PanelPlacement? = nil) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let resolved = placement ?? model.settings.panelPlacement
        var origin: NSPoint
        if resolved == .center {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        } else {
            origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    /**
     * 监听面板外的鼠标按下，用来点击外部关闭。
     */
    private func installOutsideMonitor() {
        if outsideMonitor != nil { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePanel()
            }
        }
    }

    /**
     * 监听面板作为关键窗口时的按键。
     */
    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /**
     * 搜索框是否正在编辑。
     *
     * 为 true 时，Delete、左右方向键和 ⌘Z 交给输入框。
     */
    private var isSearchEditing: Bool {
        (panel.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    /**
     * 处理主面板快捷键。
     *
     * 清空确认框打开时把回车和 Esc 交给确认框。搜索框编辑中，Delete、左右方向键和 ⌘Z 交给输入框。
     * ⌘⌫ 始终清空。回车按修饰键选择粘贴、只复制或纯文本。
     *
     * @param event 按键事件
     * @return 已消费时返回 true，调用方应吞掉事件
     */
    private func handle(_ event: NSEvent) -> Bool {
        if model.confirmClearAll {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Escape) {
            closePanel()
            return true
        }
        let commandOnly = flags.intersection([.command, .shift, .option, .control]) == .command
        if event.keyCode == UInt16(kVK_Delete) && commandOnly {
            if !model.items.isEmpty {
                model.confirmClearAll = true
            }
            return true
        }
        if isSearchEditing && passesToSearchField(event, flags: flags) {
            return false
        }
        if event.keyCode == UInt16(kVK_Return) {
            if flags.contains(.command) {
                model.paste(mode: .copyOnly)
            } else if flags.contains(.shift) {
                model.paste(mode: .plainText)
            } else {
                model.paste(mode: .automatic)
            }
            return true
        }
        if event.keyCode == UInt16(kVK_Delete) && !flags.contains(.command) {
            if model.items.first(where: { $0.id == model.selectedID })?.pinned == true {
                model.banner = L10n.text("置顶条目需要确认后再删除", "Pinned items need confirmation")
            } else {
                model.deleteSelected()
            }
            return true
        }
        if flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "z" {
            model.undoDelete()
            return true
        }
        if flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "p" {
            model.togglePin()
            return true
        }
        if flags.contains(.command), let character = event.charactersIgnoringModifiers, let number = Int(character), (1...9).contains(number) {
            let visible = model.visibleItems()
            if number <= visible.count {
                model.paste(mode: .automatic, itemID: visible[number - 1].id)
            }
            return true
        }
        if event.keyCode == UInt16(kVK_DownArrow) || event.keyCode == UInt16(kVK_UpArrow) {
            moveSelection(down: event.keyCode == UInt16(kVK_DownArrow))
            return true
        }
        return false
    }

    /**
     * 判断按键是否应留给搜索框。
     *
     * 编辑中的 Delete、左右方向键、Home、End，以及 ⌘Z、⌘A、⌘C、⌘V、⌘X 交给输入框。
     *
     * @param event 按键事件
     * @param flags 已去掉设备相关位的修饰键
     * @return 应交给搜索框时返回 true
     */
    private func passesToSearchField(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.command) {
            let character = event.charactersIgnoringModifiers?.lowercased()
            return character == "z" || character == "a" || character == "c" || character == "v" || character == "x"
        }
        if flags.contains(.option) || flags.contains(.control) {
            return false
        }
        let editing: Set<UInt16> = [
            UInt16(kVK_Delete),
            UInt16(kVK_ForwardDelete),
            UInt16(kVK_LeftArrow),
            UInt16(kVK_RightArrow),
            UInt16(kVK_Home),
            UInt16(kVK_End)
        ]
        return editing.contains(event.keyCode)
    }

    /**
     * 在当前筛选结果里上下移动选中项。
     *
     * @param down true 为下一条，false 为上一条
     */
    private func moveSelection(down: Bool) {
        let visible = model.visibleItems()
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == model.selectedID } ?? 0
        let next = down ? min(visible.count - 1, index + 1) : max(0, index - 1)
        model.selectedID = visible[next].id
    }
}
