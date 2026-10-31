import AppKit
import Carbon
import Foundation

/**
 * 全局快捷键。
 *
 * 用 Carbon RegisterEventHotKey 注册单个热键，不申请输入监控。
 * 注册前先注销旧热键。单独的 ⌘C、⌘V、⌘X、⌘Q 由 HotkeyCodec 拒绝，不在这里判断。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
final class HotkeyCenter {
    /** 进程内唯一的热键中心。 */
    static let shared = HotkeyCenter()

    /** 热键按下后的回调，在主线程执行。 */
    var onPressed: () -> Void = {}
    /** 最近一次注册是否失败。失败时设置页把快捷键标红。 */
    private(set) var registrationFailed = false
    /** 当前注册的热键。 */
    private var hotKey: EventHotKeyRef?
    /** 当前安装的事件处理。 */
    private var handler: EventHandlerRef?

    /**
     * 注册全局热键。
     *
     * 会先注销上一次注册。系统拒绝时返回 false，旧热键不再有效。
     *
     * @param keyCode 虚拟键码
     * @param modifiers Carbon 修饰键，由 cmdKey、shiftKey、optionKey、controlKey 组合
     * @return 注册成功时返回 true
     */
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &eventType, selfPointer, &handler)
        let hotKeyID = EventHotKeyID(signature: fourChar("CLAP"), id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        registrationFailed = status != noErr
        return status == noErr
    }

    /**
     * 注销当前热键和事件处理。
     */
    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    /**
     * 把热键事件转到主线程回调。
     */
    fileprivate func fire() {
        DispatchQueue.main.async { [weak self] in
            self?.onPressed()
        }
    }
}

private let hotkeyCallback: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue().fire()
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
