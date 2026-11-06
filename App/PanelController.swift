import AppKit
import Carbon
import SwiftUI

/**
 * 主面板窗口。
 *
 * 使用 nonactivatingPanel，呼出时不抢走原应用焦点。becomesKeyOnlyIfNeeded 关闭后，
 * 打开时面板成为关键窗口并聚焦搜索框。打开时记下前台应用；关闭时不改剪切板。
 * 全局热键调用方传入屏幕中心，菜单打开则使用「面板位置」设置。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    let panel: NSPanel
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    /**
     * 面板作为关键窗口时的按键处理。
     *
     * 与本地监听使用同一个闭包。测试直接调用它，避免把按键送进当前前台应用。
     */
    private(set) var keyDown: ((NSEvent) -> NSEvent?)?
    /**
     * 面板外鼠标按下时关闭面板。
     *
     * 与全局监听使用同一个闭包。测试直接调用它，全局监听收不到本进程发出的事件。
     */
    private(set) var outsideMouseDown: ((NSEvent) -> Void)?

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
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panelIsKey = { [weak self] in self?.panel.isKeyWindow == true }
        panel.minSize = NSSize(width: 420, height: 360)
        panel.contentViewController = NSHostingController(rootView: HistoryPanelView().environmentObject(model))
        applyAppearance()
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
     * 默认先记下前台应用并清掉上一次提示，再聚焦搜索框。粘贴失败后重新打开时前两项都跳过，以保留提示和原目标。
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
        applyAppearance()
        var frame = panel.frame
        frame.size = NSSize(width: model.settings.panelWidth, height: model.settings.panelHeight)
        frame.origin = origin(for: frame.size, placement: placement)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        installOutsideMonitor()
        focusSearchField()
    }

    /**
     * 把当前外观写到主面板。
     *
     * 面板已经打开时立刻切换，不必等下次 show。跟随系统时写入 nil，窗口改回跟随系统。
     */
    func applyAppearance() {
        panel.appearance = model.settings.appearance.nsAppearance
    }

    /**
     * 粘贴失败后重新打开面板，保留失败提示和原来的粘贴目标。
     */
    func showFeedback() {
        guard !panel.isVisible else { return }
        show(rememberingFrontApp: false, clearingBanner: false)
    }

    /**
     * 立刻聚焦搜索框，并在下一轮主队列复查。
     *
     * 打开时会发布辅助功能和提示，SwiftUI 可能随后把焦点交给列表。
     * 复查看的是当前第一响应者，焦点已不在搜索框时再设一次。
     */
    private func focusSearchField() {
        panel.contentView?.layoutSubtreeIfNeeded()
        makeSearchFieldFirstResponder(reportFailure: false)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.retrySearchFieldFocus()
            }
        }
    }

    /**
     * 焦点不在搜索框时再设一次，失败则写日志。
     *
     * 打开时的同步尝试失败不记录。下一轮主队列仍失败才记录。
     */
    func retrySearchFieldFocus() {
        guard panel.isVisible, !isSearchEditing else { return }
        makeSearchFieldFirstResponder(reportFailure: true)
    }

    /**
     * 在面板内容里找到搜索框并请求焦点。
     *
     * 主面板只有这一个文本框。窗口尚未成为关键窗口时，成为第一响应者也会把它变成关键窗口。
     * 同步尝试失败先不记录，留给复查；复查仍失败时写一条不含剪切板正文的日志。
     *
     * @param reportFailure 失败时是否写日志
     */
    private func makeSearchFieldFirstResponder(reportFailure: Bool) {
        guard panel.isVisible else { return }
        guard let textField = firstTextField(in: panel.contentView) else {
            if reportFailure {
                AppLog.store.error("search field missing")
            }
            return
        }
        if panel.makeFirstResponder(textField) { return }
        if reportFailure {
            AppLog.store.error("search field refused first responder")
        }
    }

    /**
     * 深度优先查找第一个文本框。
     *
     * @param view 起始视图。为空时返回空
     * @return 找到的文本框
     */
    private func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField {
            return field
        }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    /**
     * 关闭面板。
     *
     * 取消尚未确认的清空和删除置顶，丢掉单条删除的撤销，记下当前尺寸，并卸掉按键和面板外点击监听。不修改剪切板。
     */
    func closePanel() {
        model.confirmClearAll = false
        model.cancelPinnedDelete()
        model.discardUndo()
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
        let screen = Self.screen(containing: mouse, screens: NSScreen.screens, main: NSScreen.main)
        let visible = Self.visibleArea(of: screen)
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
     * 找出鼠标所在的屏幕。没有一块屏幕包含这个点时返回主屏幕。
     *
     * @param mouse 鼠标位置
     * @param screens 候选屏幕
     * @param main 主屏幕，可以为空
     * @return 命中的屏幕
     */
    static func screen(containing mouse: NSPoint, screens: [NSScreen], main: NSScreen?) -> NSScreen? {
        screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }

    /**
     * 取屏幕可见区域。没有屏幕时返回 1280×800。
     *
     * @param screen 用来摆放面板的屏幕
     * @return 可见区域
     */
    static func visibleArea(of screen: NSScreen?) -> NSRect {
        screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /**
     * 监听面板外的鼠标按下，用来点击外部关闭。
     */
    private func installOutsideMonitor() {
        if outsideMonitor != nil { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePanel()
            }
        }
        outsideMouseDown = handler
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler)
    }

    /**
     * 监听面板作为关键窗口时的按键。
     */
    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self, self.panelIsKey() else { return event }
            return self.handle(event) ? nil : event
        }
        keyDown = handler
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    /**
     * 面板当前是否为关键窗口。
     *
     * 按键监听用它决定要不要消费按键。测试可以换成固定结果，避免依赖进程能否成为前台。
     */
    var panelIsKey: () -> Bool = { false }

    /**
     * 搜索框是否正在编辑。
     *
     * 为 true 时，Delete、左右方向键交给输入框，⌘A、⌘C、⌘V、⌘X、⌘Z 发给字段编辑器。
     */
    private var isSearchEditing: Bool {
        (panel.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    /**
     * 处理主面板快捷键。
     *
     * 清空或删除置顶的确认框打开时，把回车和 Esc 交给确认框。搜索框编辑中，Delete、左右方向键、Home、End 交给输入框。
     * ⌘A、⌘C、⌘V、⌘X、⌘Z、⌘⇧Z 由本方法发给字段编辑器。面板不激活应用，系统不会把这些组合键转成编辑动作。
     * ⌘⌫ 始终清空。回车按修饰键选择粘贴、只复制或纯文本。⌫ 删除当前条；置顶条目改为打开确认框。
     *
     * @param event 按键事件
     * @return 已消费时返回 true，调用方应吞掉事件
     */
    func handle(_ event: NSEvent) -> Bool {
        if ItemDeleteRouting.yieldsKeysToConfirmation(
            confirmClearAll: model.confirmClearAll,
            confirmPinnedDelete: model.confirmPinnedDelete
        ) {
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
        if isSearchEditing {
            if let action = searchEditingAction(for: event, flags: flags) {
                performSearchEditingAction(action)
                return true
            }
            if passesToSearchField(event, flags: flags) {
                return false
            }
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
            model.deleteSelected()
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
     * 把搜索框编辑动作发给当前字段编辑器。
     *
     * 选择、复制、粘贴、剪切由字段编辑器处理。撤销和重做不在 NSTextView 的选择子上，
     * 直接发送会抛出无法识别的选择子，所以改走它的撤销管理器。目标是面板自己的第一响应者，
     * 不走关键窗口，避免面板尚未成为关键窗口时改到别的窗口。
     *
     * @param action 由 searchEditingAction 选出的动作
     */
    private func performSearchEditingAction(_ action: Selector) {
        guard let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor else { return }
        if action == Selector(("undo:")) {
            editor.undoManager?.undo()
        } else if action == Selector(("redo:")) {
            editor.undoManager?.redo()
        } else {
            NSApp.sendAction(action, to: editor, from: nil)
        }
    }

    /**
     * 搜索框编辑时要直接发给字段编辑器的动作。
     *
     * 面板不激活应用，也没有编辑菜单，系统不会处理这些快捷键。只认单独的 ⌘，以及用来重做的 ⌘⇧Z。
     *
     * @param event 按键事件
     * @param flags 已去掉设备相关位的修饰键
     * @return 发给字段编辑器的动作。不是这组快捷键时返回空
     */
    func searchEditingAction(for event: NSEvent, flags: NSEvent.ModifierFlags) -> Selector? {
        let modifiers = flags.intersection([.command, .shift, .option, .control])
        guard modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control) else {
            return nil
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where modifiers == .command:
            return #selector(NSText.selectAll(_:))
        case "c" where modifiers == .command:
            return #selector(NSText.copy(_:))
        case "v" where modifiers == .command:
            return #selector(NSText.paste(_:))
        case "x" where modifiers == .command:
            return #selector(NSText.cut(_:))
        case "z" where modifiers == .command:
            return Selector(("undo:"))
        case "z" where modifiers == [.command, .shift]:
            return Selector(("redo:"))
        default:
            return nil
        }
    }

    /**
     * 判断按键是否应原样留给搜索框。
     *
     * 编辑中的 Delete、左右方向键、Home、End 走文本系统的按键绑定。⌘A、⌘C、⌘V、⌘X、⌘Z 不在这里，它们要另行发送动作。
     *
     * @param event 按键事件
     * @param flags 已去掉设备相关位的修饰键
     * @return 应交给搜索框的按键处理时返回 true
     */
    func passesToSearchField(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
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
