import AppKit
import ApplicationServices
import Carbon
import Foundation

/**
 * 辅助功能权限。
 *
 * 只用于向其他应用发送 ⌘V。采集历史不依赖这项权限。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum AccessibilityClient {
    /** 系统设置里辅助功能页的地址。 */
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /**
     * 查询辅助功能是否已授权。测试可换成不访问系统的实现。
     *
     * 参数为 true 时表示这次查询希望弹出系统授权提示。
     */
    static var queryTrusted: (Bool) -> Bool = { prompt in
        readTrusted(promptOptions(prompt))
    }

    /** 让应用变为活动状态。测试可换成记录调用的实现。 */
    static var activateApp: () -> Void = { NSApp.activate(ignoringOtherApps: true) }

    /** 打开一个地址。测试可换成记录地址的实现。 */
    static var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /**
     * 查询辅助功能是否已授权。
     *
     * @param prompt 为 true 时，未授权会弹出系统授权提示
     * @return 已授权时返回 true
     */
    static func isTrusted(prompt: Bool = false) -> Bool {
        queryTrusted(prompt)
    }

    /**
     * 构造辅助功能查询选项。
     *
     * @param prompt 为 true 时带上系统授权提示选项
     * @return 不需要提示时返回 nil
     */
    static func promptOptions(_ prompt: Bool) -> CFDictionary? {
        guard prompt else { return nil }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return [key: true] as CFDictionary
    }

    /**
     * 按选项读取辅助功能授权。
     *
     * 选项为 nil 时不弹出系统提示。带提示选项时才可能出现系统对话框。
     *
     * @param options 传给 AXIsProcessTrustedWithOptions 的选项。nil 时只查询
     * @return 已授权时返回 true
     */
    static func readTrusted(_ options: CFDictionary?) -> Bool {
        if let options {
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /**
     * 打开系统设置中的辅助功能页。
     */
    static func openSettings() {
        openURL(settingsURL)
    }

    /**
     * 弹出系统授权提示，并打开系统设置中的辅助功能页。
     *
     * 先激活应用。辅助功能提示只在应用处于活动状态时出现，菜单栏应用和未激活面板上的按钮否则弹不出来。
     * 已授权时不再弹出提示，仍然打开设置页，方便核对开关。
     *
     * @return 调用提示时已经授权，或用户在提示里完成授权，返回 true
     */
    @discardableResult
    static func promptAndOpenSettings() -> Bool {
        activateApp()
        let trusted = isTrusted(prompt: true)
        openSettings()
        return trusted
    }
}

/**
 * 向当前焦点发送 ⌘V。
 *
 * 调用前应先激活原来的前台应用。未授权时直接返回 false，不发事件。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum KeystrokeSender {
    /**
     * 发送一次 ⌘V 的按下和抬起。
     *
     * @return 两个事件都创建成功时返回 true。这只表示事件已提交，不表示目标应用一定粘贴成功
     */
    /** 投递按键事件。测试可换成空操作，避免把 ⌘V 发到当前前台应用。 */
    static var postEvent: (CGEvent) -> Void = { event in
        event.post(tap: .cghidEventTap)
    }

    /**
     * 创建 ⌘V 的按下和抬起。测试可换成空事件，避免真的把按键发出去。
     */
    static var makeCommandVEvents: () -> (CGEvent?, CGEvent?) = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        return (keyDown, keyUp)
    }

    static func sendCommandV() -> Bool {
        guard AccessibilityClient.isTrusted() else { return false }
        let (keyDown, keyUp) = makeCommandVEvents()
        if let keyDown { postEvent(keyDown) }
        if let keyUp { postEvent(keyUp) }
        return keyDown != nil && keyUp != nil
    }
}
