import AppKit
import Carbon
import Foundation

/**
 * 向系统登记或卸下全局热键。
 *
 * 测试可以换成不碰 Carbon 的实现，用来覆盖注册成功、失败和注销。
 */
protocol HotkeyBackend: AnyObject {
    /**
     * 安装热键事件处理。
     *
     * 已经安装时直接返回 true。
     *
     * @param center 收到按键后负责分发的热键中心
     * @return 安装成功时返回 true
     */
    func installHandler(for center: HotkeyCenter) -> Bool

    /**
     * 卸掉热键事件处理。
     *
     * 尚未安装时什么也不做。
     */
    func removeHandler()

    /**
     * 向系统注册一组热键。
     *
     * 同一编号已有登记时，新组合被接受后才卸掉旧的。系统拒绝时旧组合保持有效。
     *
     * @param keyCode 虚拟键码
     * @param modifiers Carbon 修饰键
     * @param id 热键编号
     * @return 系统接受时返回 true
     */
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool

    /**
     * 注销一组热键。
     *
     * 这一组没有登记时什么也不做。
     *
     * @param id 热键编号
     */
    func unregister(id: UInt32)
}

/**
 * 应用模型用来注册两组全局热键的接口。
 */
protocol GlobalHotkeys: AnyObject {
    /**
     * 注册一组热键。
     *
     * @param id 热键编号
     * @param keyCode 虚拟键码
     * @param modifiers Carbon 修饰键
     * @param onPressed 按下后在主线程执行的回调
     * @return 注册成功时返回 true
     */
    func register(id: HotkeyCenter.ID, keyCode: UInt32, modifiers: UInt32, onPressed: @escaping () -> Void) -> Bool

    /**
     * 注销一组热键。
     *
     * @param id 热键编号
     */
    func unregister(id: HotkeyCenter.ID)
}

/**
 * 全局快捷键。
 *
 * 用 Carbon RegisterEventHotKey 同时注册打开面板和暂停两组热键，不申请输入监控。
 * 重新注册某一组时先登记新组合，成功后再卸掉这一组的旧热键。登记失败时保留原来的登记和回调。
 * 单独的 ⌘C、⌘V、⌘X、⌘Q 由 HotkeyCodec 拒绝，不在这里判断。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
final class HotkeyCenter: GlobalHotkeys {
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
    static let shared = HotkeyCenter(backend: CarbonHotkeyBackend())

    /** 按编号保存的回调。系统热键引用放在 backend 里。 */
    private var callbacks: [UInt32: () -> Void] = [:]
    /** 事件处理是否已经安装。 */
    private var handlerInstalled = false
    /** 实际向系统登记热键的对象。 */
    private let backend: HotkeyBackend

    /**
     * 用指定的登记实现创建热键中心。
     *
     * @param backend 系统热键登记
     */
    init(backend: HotkeyBackend) {
        self.backend = backend
    }

    /**
     * 注册一组全局热键。
     *
     * 先向系统登记新组合。成功后再换成新回调。系统拒绝时保留这一组原来的登记和回调，另一组不受影响。
     *
     * @param id 热键编号
     * @param keyCode 虚拟键码
     * @param modifiers Carbon 修饰键，由 cmdKey、shiftKey、optionKey、controlKey 组合
     * @param onPressed 热键按下后在主线程执行的回调
     * @return 注册成功时返回 true
     */
    func register(id: ID, keyCode: UInt32, modifiers: UInt32, onPressed: @escaping () -> Void) -> Bool {
        if !handlerInstalled {
            guard backend.installHandler(for: self) else { return false }
            handlerInstalled = true
        }
        guard backend.register(keyCode: keyCode, modifiers: modifiers, id: id.rawValue) else {
            if callbacks.isEmpty {
                backend.removeHandler()
                handlerInstalled = false
            }
            return false
        }
        callbacks[id.rawValue] = onPressed
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
        guard callbacks.removeValue(forKey: id.rawValue) != nil else { return }
        backend.unregister(id: id.rawValue)
        if callbacks.isEmpty {
            backend.removeHandler()
            handlerInstalled = false
        }
    }

    /**
     * 按热键编号调用对应回调。
     *
     * 回调先取出再派发。派发前注销只会让尚未取出的编号失效，已经取出的回调仍会执行。
     *
     * @param id RegisterEventHotKey 时写入的编号
     */
    func fire(id: UInt32) {
        let action = callbacks[id]
        DispatchQueue.main.async {
            action?()
        }
    }

    /**
     * 从热键事件里读出编号并分发。
     *
     * 事件里没有热键编号时返回 noErr，不调用回调。
     *
     * @param event 系统发来的热键事件，缺失时忽略
     * @return 始终返回 noErr，避免事件处理被移掉
     */
    func accept(event: EventRef?) -> OSStatus {
        guard let event else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = withUnsafeMutableBytes(of: &hotKeyID) { buffer -> OSStatus in
            guard let bytes = buffer.baseAddress else { return OSStatus(paramErr) }
            return GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                buffer.count,
                nil,
                bytes
            )
        }
        guard status == noErr else { return noErr }
        fire(id: hotKeyID.id)
        return noErr
    }
}

/**
 * Carbon 热键事件进入应用后的转发。
 *
 * 没有用户数据时直接返回。有用户数据时交给对应的热键中心。
 */
enum HotkeyEvents {
    /**
     * 处理一次热键事件。
     *
     * @param event 系统事件
     * @param userData 注册时写入的热键中心指针
     * @return 始终返回 noErr
     */
    static func deliver(event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
        guard let userData else { return noErr }
        return Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue().accept(event: event)
    }
}

let hotkeyCallback: EventHandlerUPP = { _, event, userData in
    HotkeyEvents.deliver(event: event, userData: userData)
}

/**
 * 使用 Carbon 登记两组全局热键。
 */
final class CarbonHotkeyBackend: HotkeyBackend {
    /** 当前安装的事件处理。 */
    private var handler: EventHandlerRef?
    /** 已向系统登记的热键。 */
    private var keys: [UInt32: RegisteredHotKey] = [:]

    /**
     * 一组已经交给系统的热键。
     *
     * 保留键码和修饰键，相同组合再次登记时不必向系统再注册一次。
     */
    private struct RegisteredHotKey {
        /** 虚拟键码。 */
        var keyCode: UInt32
        /** Carbon 修饰键。 */
        var modifiers: UInt32
        /** 系统返回的热键引用。 */
        var hotKey: EventHotKeyRef
    }

    func installHandler(for center: HotkeyCenter) -> Bool {
        guard handler == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(center).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &eventType, selfPointer, &handler)
        return handler != nil
    }

    func removeHandler() {
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        if let existing = keys[id], existing.keyCode == keyCode, existing.modifiers == modifiers {
            return true
        }
        var hotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourChar("CLAP"), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr, let hotKey else { return false }
        if let existing = keys.removeValue(forKey: id) {
            UnregisterEventHotKey(existing.hotKey)
        }
        keys[id] = RegisteredHotKey(keyCode: keyCode, modifiers: modifiers, hotKey: hotKey)
        return true
    }

    func unregister(id: UInt32) {
        guard let existing = keys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(existing.hotKey)
    }
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

    /**
     * 判断正在录制的这一组是否和另一组使用了同一个组合。
     *
     * 暂停热键还没设置时，录制打开主面板不受它影响。
     *
     * @param recording 正在录制的热键
     * @param code 这次按下的虚拟键码
     * @param modifiers 这次按下的 Carbon 修饰键
     * @param panelCode 打开主面板的虚拟键码
     * @param panelModifiers 打开主面板的 Carbon 修饰键
     * @param pauseCode 暂停热键的虚拟键码
     * @param pauseModifiers 暂停热键的 Carbon 修饰键
     * @param pauseIsSet 暂停热键是否已经录制
     * @return 两组相同时返回 true
     */
    static func duplicates(
        recording: HotkeyCenter.ID,
        code: Int,
        modifiers: Int,
        panelCode: Int,
        panelModifiers: Int,
        pauseCode: Int,
        pauseModifiers: Int,
        pauseIsSet: Bool
    ) -> Bool {
        switch recording {
        case .panel:
            return pauseIsSet && pauseCode == code && pauseModifiers == modifiers
        case .pause:
            return panelCode == code && panelModifiers == modifiers
        }
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
