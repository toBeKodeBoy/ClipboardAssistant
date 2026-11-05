import AppKit
import Carbon
import Foundation

/**
 * 全局快捷键。
 *
 * 用 Carbon RegisterEventHotKey 同时注册打开面板和暂停两组热键，不申请输入监控。
 * 重新注册某一组时只注销这一组。单独的 ⌘C、⌘V、⌘X、⌘Q 由 HotkeyCodec 拒绝，不在这里判断。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
final class HotkeyCenter {
    /**
     * 两组热键的编号。
     *
     * 编号不同，系统才会把它们当成两个热键。
     */
    enum ID: UInt32 {
        /** 打开或关闭主面板。 */
        case panel = 1
        /** 暂停或恢复采集。 */
        case pause = 2
    }

    /** 进程内唯一的热键中心。 */
    static let shared = HotkeyCenter()

    /** 已注册的热键和它的回调。 */
    private struct Slot {
        var hotKey: EventHotKeyRef
        var onPressed: () -> Void
    }

    /** 按编号保存的热键。 */
    private var slots: [UInt32: Slot] = [:]
    /** 当前安装的事件处理。两组热键共用。 */
    private var handler: EventHandlerRef?

    /**
     * 注册一组全局热键。
     *
     * 会先注销同一编号的旧热键。系统拒绝时返回 false，这一组不再有效，另一组保持原样。
     *
     * @param id 热键编号
     * @param keyCode 虚拟键码
     * @param modifiers Carbon 修饰键，由 cmdKey、shiftKey、optionKey、controlKey 组合
     * @param onPressed 热键按下后在主线程执行的回调
     * @return 注册成功时返回 true
     */
    func register(id: ID, keyCode: UInt32, modifiers: UInt32, onPressed: @escaping () -> Void) -> Bool {
        unregister(id: id)
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: fourChar("CLAP"), id: id.rawValue)
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr, let hotKey else {
            if slots.isEmpty {
                removeHandler()
            }
            return false
        }
        slots[id.rawValue] = Slot(hotKey: hotKey, onPressed: onPressed)
        return true
    }

    /**
     * 注销一组热键。
     *
     * 这一组本来就没有注册时什么也不做。两组都注销后卸掉事件处理。
     *
     * @param id 热键编号
     */
    func unregister(id: ID) {
        guard let slot = slots.removeValue(forKey: id.rawValue) else { return }
        UnregisterEventHotKey(slot.hotKey)
        if slots.isEmpty {
            removeHandler()
        }
    }

    /**
     * 按事件里的热键编号调用对应回调。
     *
     * 回调先取出再派发，避免注销发生在派发之前时调用到已经换掉的热键。
     *
     * @param id RegisterEventHotKey 时写入的编号
     */
    fileprivate func fire(id: UInt32) {
        let action = slots[id]?.onPressed
        DispatchQueue.main.async {
            action?()
        }
    }

    /**
     * 安装一次键盘热键事件处理。
     */
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &eventType, selfPointer, &handler)
    }

    /**
     * 卸掉键盘热键事件处理。
     */
    private func removeHandler() {
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }
}

private let hotkeyCallback: EventHandlerUPP = { _, event, userData in
    guard let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return noErr }
    Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue().fire(id: hotKeyID.id)
    return noErr
}

/**
 * 把最多四个 ASCII 字符收成 OSType。
 *
 * 热键签名使用 "CLAP"。
 *
 * @param string 源字符串，超出四个字符的部分忽略
 * @return 四字符码
 */
func fourChar(_ string: String) -> OSType {
    var result: OSType = 0
    for byte in string.utf8.prefix(4) {
        result = (result << 8) + OSType(byte)
    }
    return result
}

/**
 * 暂停热键要不要注册。
 *
 * 显示文案为空表示用户没有设置，不注册。和打开主面板使用同一组合时记为冲突，也不注册。
 *
 * @author toBeKodeBoy
 * @date 2026/11/05
 */
enum HotkeyPlan {
    /**
     * 暂停热键的注册结论。
     */
    enum Pause: Equatable {
        /** 没有设置，保持未注册。 */
        case skip
        /** 和打开主面板的组合相同，不注册。 */
        case conflict
        /**
         * 可以注册。
         *
         * @param keyCode 虚拟键码
         * @param modifiers Carbon 修饰键
         */
        case register(keyCode: UInt32, modifiers: UInt32)
    }

    /**
     * 判断已保存的暂停热键是否应该注册。
     *
     * @param code 暂停热键的虚拟键码
     * @param modifiers 暂停热键的 Carbon 修饰键
     * @param display 设置页显示的文案。空字符串表示未设置
     * @param panelCode 打开主面板的虚拟键码
     * @param panelModifiers 打开主面板的 Carbon 修饰键
     * @return 跳过、冲突或可以注册
     */
    static func pause(
        code: Int,
        modifiers: Int,
        display: String,
        panelCode: Int,
        panelModifiers: Int
    ) -> Pause {
        guard !display.isEmpty else { return .skip }
        if code == panelCode && modifiers == panelModifiers {
            return .conflict
        }
        return .register(keyCode: UInt32(code), modifiers: UInt32(modifiers))
    }
}

/**
 * 快捷键的修饰键转换和保留键判断。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum HotkeyCodec {
    /**
     * 把 AppKit 修饰键转成 Carbon 热键修饰键。
     *
     * @param flags 按键事件里的修饰键
     * @return cmdKey、shiftKey、optionKey、controlKey 的组合
     */
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    /**
     * 判断是否为不允许注册的系统快捷键。
     *
     * 只拒绝单独的 ⌘C、⌘V、⌘X、⌘Q。带其他修饰键的组合可以注册。
     *
     * @param keyCode 虚拟键码
     * @param flags 修饰键
     * @return 应拒绝时返回 true
     */
    static func isReserved(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let onlyCommand = flags.intersection([.command, .shift, .option, .control]) == .command
        let reserved: Set<UInt16> = [
            UInt16(kVK_ANSI_C),
            UInt16(kVK_ANSI_V),
            UInt16(kVK_ANSI_X),
            UInt16(kVK_ANSI_Q)
        ]
        return onlyCommand && reserved.contains(keyCode)
    }

    /**
     * 生成设置页显示的快捷键文案。
     *
     * @param keyCode 虚拟键码，fallback 为空时用来查键名
     * @param flags 修饰键，按 ⌃⌥⇧⌘ 的顺序排列
     * @param fallback 事件里已经给出的字符；为空时改用键名表
     * @return 例如 ⌘⇧V
     */
    static func display(keyCode: UInt16, flags: NSEvent.ModifierFlags, fallback: String) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        let glyph = fallback.isEmpty ? keyName(keyCode) : fallback.uppercased()
        parts.append(glyph)
        return parts.joined()
    }

    /**
     * 把虚拟键码转成可读键名。
     *
     * @param keyCode 虚拟键码
     * @return 字母、符号或 #键码
     */
    private static func keyName(_ keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
            UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
            UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
            UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
            UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
            UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
            UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
            UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
            UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
            UInt16(kVK_Return): "↩", UInt16(kVK_Space): "Space", UInt16(kVK_Delete): "⌫",
            UInt16(kVK_Escape): "Esc", UInt16(kVK_Tab): "⇥"
        ]
        return map[keyCode] ?? "#\(keyCode)"
    }
}
