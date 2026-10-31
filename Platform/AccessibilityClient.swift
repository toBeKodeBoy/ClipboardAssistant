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
    /**
     * 查询辅助功能是否已授权。
     *
     * @param prompt 为 true 时，未授权会弹出系统授权提示
     * @return 已授权时返回 true
     */
    static func isTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /**
     * 打开系统设置中的辅助功能页。
     */
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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
    static func sendCommandV() -> Bool {
        guard AccessibilityClient.isTrusted() else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        return keyDown != nil && keyUp != nil
    }
}
