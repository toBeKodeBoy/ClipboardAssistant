import AppKit
import Carbon
import Foundation

final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onPressed: () -> Void = {}
    private(set) var registrationFailed = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

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

func fourChar(_ string: String) -> OSType {
    var result: OSType = 0
    for byte in string.utf8.prefix(4) {
        result = (result << 8) + OSType(byte)
    }
    return result
}

enum HotkeyCodec {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

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
