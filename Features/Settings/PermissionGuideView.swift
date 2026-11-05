import AppKit
import SwiftUI

/**
 * 权限说明里的句子。
 *
 * 每种语言各自拼好完整句子，避免把当前语言的失败提示嵌进另一种语言。
 */
enum PermissionGuideCopy {
    /** 说明页宽度。窗口按这个宽度排版，高度随内容变化。 */
    static let width: CGFloat = 460

    static var historyNote: String {
        L10n.text(historyNoteZH, historyNoteEN)
    }

    static var historyNoteZH: String {
        "未授权时仍会记录历史。复制和只写入剪切板不受影响。自动粘贴会提示「\(PasteOutcome.manualPasteMessageZH)」。"
    }

    static var historyNoteEN: String {
        "History is still recorded without it. Copy and copy-only keep working. Automatic paste shows “\(PasteOutcome.manualPasteMessageEN).”"
    }

    /**
     * 从两组测量里挑一个可用高度。
     *
     * 过小或过大的值丢掉。两组都不可用时返回 360，页面里的滚动区域承接更长的内容。
     *
     * @param intrinsic 宿主视图的固有高度
     * @param preferred 宿主控制器报告的首选高度
     * @return 220 到 640 之间的高度，或 360
     */
    static func usableHeight(intrinsic: CGFloat, preferred: CGFloat) -> CGFloat {
        for candidate in [intrinsic, preferred] where (220...640).contains(candidate) {
            return candidate
        }
        return 360
    }
}

/**
 * 权限说明窗口的位置。
 *
 * 放在菜单栏图标正下方。超出屏幕时收回可见区域，过高时压到屏幕高度，内容改由页面滚动。
 */
enum PermissionGuideLayout {
    /**
     * 计算说明窗口的框架。
     *
     * @param window 当前窗口框架，只用宽高
     * @param buttonFrame 菜单栏按钮在屏幕上的框架
     * @param visible 按钮所在屏幕的可见区域。nil 时不限制
     * @return 调整后的窗口框架
     */
    static func frame(window: NSRect, buttonFrame: NSRect, visible: NSRect?) -> NSRect {
        var frame = window
        frame.origin.x = buttonFrame.midX - frame.width / 2
        frame.origin.y = buttonFrame.minY - frame.height - 6
        guard let visible else { return frame }
        if frame.height > visible.height {
            frame.size.height = visible.height
            frame.origin.y = buttonFrame.minY - frame.height - 6
        }
        if frame.maxX > visible.maxX {
            frame.origin.x = visible.maxX - frame.width - 4
        }
        if frame.minX < visible.minX {
            frame.origin.x = visible.minX + 4
        }
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        if frame.maxY > visible.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        return frame
    }
}

/**
 * 辅助功能权限说明。
 *
 * 未授权时从菜单栏图标打开。说明自动粘贴为什么需要这项权限，并提供前往系统设置和打开主面板的按钮。
 * 内容高出窗口时可以滚动。
 */
struct PermissionGuideView: View {
    let onOpenSettings: () -> Void
    let onOpenPanel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("自动粘贴需要辅助功能", "Automatic paste needs Accessibility"))
                    .font(.title3)
                Text(L10n.text(
                    "这项权限用来向原来的应用发送 ⌘V，把选中的历史贴回去。请在「系统设置 › 隐私与安全性 › 辅助功能」中允许剪切板助手。",
                    "This permission sends ⌘V to the previous app so the selected history is pasted there. Allow Clipboard Assistant in System Settings › Privacy & Security › Accessibility."
                ))
                Text(PermissionGuideCopy.historyNote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(L10n.text("打开系统设置", "Open System Settings"), action: onOpenSettings)
                        .keyboardShortcut(.defaultAction)
                    Button(L10n.text("打开主面板", "Open panel"), action: onOpenPanel)
                }
                Text(L10n.text(
                    "右键或按住 Control 点击菜单栏图标，仍可打开最近记录、暂停和设置。",
                    "Right-click, or Control-click, the menu bar icon for recent items, pause, and settings."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: PermissionGuideCopy.width, alignment: .leading)
        }
        .frame(width: PermissionGuideCopy.width)
    }
}
