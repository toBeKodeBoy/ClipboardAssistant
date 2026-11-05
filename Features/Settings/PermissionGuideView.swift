import SwiftUI

/**
 * 辅助功能权限说明。
 *
 * 未授权时从菜单栏图标打开。说明自动粘贴为什么需要这项权限，并提供前往系统设置和打开主面板的按钮。
 */
struct PermissionGuideView: View {
    let onOpenSettings: () -> Void
    let onOpenPanel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("自动粘贴需要辅助功能", "Automatic paste needs Accessibility"))
                .font(.title3)
            Text(L10n.text(
                "这项权限用来向原来的应用发送 ⌘V，把选中的历史贴回去。请在「系统设置 › 隐私与安全性 › 辅助功能」中允许剪切板助手。",
                "This permission sends ⌘V to the previous app so the selected history is pasted there. Allow Clipboard Assistant in System Settings › Privacy & Security › Accessibility."
            ))
            Text(L10n.text(
                "未授权时仍会记录历史。复制和只写入剪切板不受影响。自动粘贴会提示「\(PasteOutcome.manualPasteMessage)」。",
                "History is still recorded without it. Copy and copy-only keep working. Automatic paste shows “\(PasteOutcome.manualPasteMessage).”"
            ))
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(L10n.text("打开系统设置", "Open System Settings"), action: onOpenSettings)
                    .keyboardShortcut(.defaultAction)
                Button(L10n.text("打开主面板", "Open panel"), action: onOpenPanel)
            }
            Text(L10n.text(
                "右键菜单栏图标仍可打开最近记录、暂停和设置。",
                "Right-click the menu bar icon for recent items, pause, and settings."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460, height: 340, alignment: .topLeading)
    }
}
