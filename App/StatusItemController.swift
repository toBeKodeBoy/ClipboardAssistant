import AppKit
import SwiftUI

/**
 * 菜单栏图标和菜单。
 *
 * 打开菜单时立刻记下前台应用。图标为模板图：暂停加斜杠，未授权加圆点。
 * 未授权时左键打开权限说明，右键仍打开原来的菜单。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let panel: PanelController
    private let item: NSStatusItem
    private let menu: NSMenu
    private var settingsWindow: NSWindow?
    private var permissionWindow: NSPanel?
    private var trustTimer: Timer?
    private var menuIsOpen = false

    /**
     * 创建状态栏图标，并把全局热键接到面板开关。
     *
     * 热键固定在光标所在屏幕正中打开。未授权时左键不挂菜单，改为打开权限说明。
     *
     * @param model 应用状态
     * @param panel 主面板
     */
    init(model: AppModel, panel: PanelController) {
        self.model = model
        self.panel = panel
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        super.init()
        menu.delegate = self
        model.settings.onPauseStateChange = { [weak self] in
            guard let self else { return }
            self.item.button?.image = self.icon()
        }
        model.onAccessibilityChange = { [weak self] _ in
            self?.handleAccessibilityChange()
        }
        model.refreshAccessibility()
        item.button?.image = icon()
        item.button?.image?.isTemplate = true
        applyInteraction()
        model.onHotkey = { [weak self] in
            self?.panel.toggle(placement: .center)
        }
        model.settings.onAppearanceChange = { [weak self] in
            self?.applyAppearance()
        }
        startTrustTimer()
    }

    /**
     * 菜单打开前刷新前台应用、权限、历史和图标。
     *
     * @param menu 即将打开的状态栏菜单
     */
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        model.rememberFrontApp()
        model.refreshAccessibility()
        model.reload()
        rebuild(menu)
        item.button?.image = icon()
    }

    /**
     * 菜单关闭后按当前授权状态恢复点击去向。
     *
     * 右键弹出菜单时会暂时挂上菜单。未授权则在关闭后再摘掉，避免下一次左键仍打开菜单。
     *
     * @param menu 刚关闭的状态栏菜单
     */
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        Task { @MainActor in
            self.applyInteraction()
            self.item.button?.image = self.icon()
        }
    }

    /**
     * 重建菜单：最近 10 条、打开主面板、暂停和设置。
     *
     * 最近条目不显示图标。没有历史时放一条不可点的占位。暂停热键已设置且注册成功时，把它写在暂停菜单项后面。
     *
     * @param menu 要填充的菜单
     */
    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = Array(model.items.prefix(10))
        if recent.isEmpty {
            let empty = NSMenuItem(title: L10n.text("暂无记录", "No history"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in recent {
                let menuItem = NSMenuItem(title: String(entry.title.prefix(80)), action: #selector(pasteRecent(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = entry.id
                menu.addItem(menuItem)
            }
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: L10n.text("打开主面板", "Open panel"), action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let pauseTitle = StatusMenuText.pauseItem(
            isPaused: model.settings.isPaused,
            hotkeyDisplay: model.settings.pauseHotkeyDisplay,
            available: !model.settings.pauseHotkeyConflict
        )
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    /**
     * 绘制模板图标。
     *
     * 暂停时加斜杠，辅助功能未授权时加圆点。
     *
     * @return 18 点模板图
     */
    private func icon() -> NSImage {
        let paused = model.settings.isPaused
        let trusted = model.accessibilityTrusted
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let symbol = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            symbol?.isTemplate = false
            symbol?.draw(in: rect.insetBy(dx: 1, dy: 2))
            if paused {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 3))
                slash.line(to: NSPoint(x: 15, y: 15))
                slash.lineWidth = 1.4
                NSColor.black.setStroke()
                slash.stroke()
            }
            if !trusted {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /**
     * 授权变化时重画图标，并在菜单没有打开时切换点击去向。
     *
     * 菜单正打开时只改图标。关闭菜单后再摘掉或挂回菜单，避免跟踪过程中把菜单拆掉。
     */
    private func handleAccessibilityChange() {
        item.button?.image = icon()
        guard !menuIsOpen else { return }
        applyInteraction()
    }

    /**
     * 按授权状态决定左键打开菜单还是权限说明。
     *
     * 已授权时挂上菜单。未授权时摘掉菜单，左键交给 statusClicked。
     */
    private func applyInteraction() {
        switch StatusItemInteraction.destination(accessibilityTrusted: model.accessibilityTrusted) {
        case .menu:
            item.button?.target = nil
            item.button?.action = nil
            item.menu = menu
            permissionWindow?.orderOut(nil)
        case .permissionGuide:
            item.menu = nil
            item.button?.target = self
            item.button?.action = #selector(statusClicked)
            item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }

    /**
     * 未授权时的图标点击。
     *
     * 左键打开权限说明。右键仍弹出原来的菜单。点击当下如果已经授权，改为打开菜单。
     */
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseDown || NSApp.currentEvent?.type == .rightMouseUp {
            popUpMenu()
            return
        }
        model.refreshAccessibility()
        item.button?.image = icon()
        applyInteraction()
        switch StatusItemInteraction.destination(accessibilityTrusted: model.accessibilityTrusted) {
        case .menu:
            popUpMenu()
        case .permissionGuide:
            showPermissionGuide()
        }
    }

    /**
     * 暂时挂上菜单并模拟点击，让右键走原来的菜单。
     *
     * 先清掉按钮动作，避免 performClick 再次进入 statusClicked。菜单关闭后由 menuDidClose 按授权状态决定是否再摘掉。
     */
    private func popUpMenu() {
        item.menu = menu
        item.button?.target = nil
        item.button?.action = nil
        item.button?.performClick(nil)
        if !menuIsOpen {
            applyInteraction()
        }
    }

    /**
     * 在图标下方打开权限说明。
     *
     * 使用不激活应用的面板，避免把粘贴目标改成自己。
     */
    private func showPermissionGuide() {
        let window = ensurePermissionWindow()
        applyAppearance()
        place(window)
        window.makeKeyAndOrderFront(nil)
        item.button?.highlight(false)
        AppLog.store.info("permission guide opened")
    }

    /**
     * 创建权限说明面板。
     *
     * 重复打开时复用同一扇窗口。
     *
     * @return 权限说明面板
     */
    private func ensurePermissionWindow() -> NSPanel {
        if let permissionWindow { return permissionWindow }
        let host = NSHostingController(rootView: PermissionGuideView(
            onOpenSettings: { [weak self] in self?.openAccessibilitySettings() },
            onOpenPanel: { [weak self] in self?.openPanelFromGuide() }
        ))
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("辅助功能", "Accessibility")
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentViewController = host
        window.setContentSize(NSSize(width: 460, height: 340))
        permissionWindow = window
        return window
    }

    /**
     * 把权限说明放在菜单栏图标正下方，并限制在该屏幕可见区域内。
     *
     * 图标窗口还不可用时改放到屏幕中心。
     *
     * @param window 要摆放的权限说明
     */
    private func place(_ window: NSPanel) {
        guard let button = item.button, let buttonWindow = button.window else {
            window.center()
            return
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var frame = window.frame
        frame.origin.x = buttonFrame.midX - frame.width / 2
        frame.origin.y = buttonFrame.minY - frame.height - 6
        if let screen = buttonWindow.screen {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX {
                frame.origin.x = visible.maxX - frame.width - 4
            }
            if frame.minX < visible.minX {
                frame.origin.x = visible.minX + 4
            }
            if frame.minY < visible.minY {
                frame.origin.y = visible.minY + 4
            }
            if frame.maxY > visible.maxY {
                frame.origin.y = visible.maxY - frame.height
            }
        }
        window.setFrame(frame, display: false)
    }

    /**
     * 弹出系统授权提示并打开辅助功能设置。
     *
     * 授权成功后关掉说明页，菜单栏点击恢复为普通菜单。
     */
    private func openAccessibilitySettings() {
        _ = AccessibilityClient.promptAndOpenSettings()
        model.refreshAccessibility()
    }

    /**
     * 从权限说明打开主面板。
     *
     * 先收起说明页，再按「面板位置」显示主面板，避免两扇窗口叠在一起。
     */
    private func openPanelFromGuide() {
        permissionWindow?.orderOut(nil)
        panel.show()
    }

    /**
     * 约每秒复查一次授权。
     *
     * 用户在系统设置里打开或关闭辅助功能后，圆点和点击去向不用等下一次点图标。
     */
    private func startTrustTimer() {
        trustTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshAccessibility()
            }
        }
        trustTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /**
     * 把菜单里的一条最近记录按原始类型粘贴。
     *
     * @param sender 代表最近条目的菜单项，representedObject 为条目标识
     */
    @objc private func pasteRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.paste(mode: .automatic, itemID: id)
    }

    /**
     * 按「面板位置」设置打开主面板。
     */
    @objc private func openPanel() {
        panel.show()
    }

    /**
     * 切换暂停。图标由暂停状态回调立刻重画。
     */
    @objc private func togglePause() {
        model.togglePause()
    }

    /**
     * 把当前外观写到主面板、设置窗口和权限说明。
     *
     * 对应窗口还没创建时跳过那一扇。
     */
    private func applyAppearance() {
        panel.applyAppearance()
        let appearance = model.settings.appearance.nsAppearance
        settingsWindow?.appearance = appearance
        permissionWindow?.appearance = appearance
    }

    /**
     * 打开或前置设置窗口。
     */
    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model))
            let window = NSWindow(contentViewController: host)
            window.title = L10n.text("设置", "Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 720, height: 480))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        applyAppearance()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/**
 * 菜单栏里暂停项的标题。
 *
 * 暂停热键已设置且注册成功时，把组合接在标题后面。冲突或登记失败时不展示组合。
 */
enum StatusMenuText {
    /**
     * 生成暂停或恢复菜单项的标题。
     *
     * @param isPaused 当前是否暂停
     * @param hotkeyDisplay 暂停热键文案。空字符串表示未设置
     * @param available 这一组是否已向系统登记成功。冲突或登记失败时为 false
     * @return 菜单项标题
     */
    static func pauseItem(isPaused: Bool, hotkeyDisplay: String, available: Bool = true) -> String {
        let title = isPaused ? L10n.text("恢复记录", "Resume") : L10n.text("暂停记录", "Pause")
        guard available, !hotkeyDisplay.isEmpty else { return title }
        return title + "  " + hotkeyDisplay
    }
}
