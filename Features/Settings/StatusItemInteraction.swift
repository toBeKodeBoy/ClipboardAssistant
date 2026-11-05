import Foundation

/**
 * 点击菜单栏图标时打开哪一块界面。
 *
 * 辅助功能未授权时进入权限说明。已授权时打开普通菜单。
 */
enum StatusClickDestination: Equatable {
    /// 最近记录、打开主面板、暂停和设置。
    case menu
    /// 说明辅助功能用途，并提供前往系统设置的按钮。
    case permissionGuide
}

/**
 * 按辅助功能是否授权决定菜单栏点击的去向。
 */
enum StatusItemInteraction {
    /**
     * 决定这一次点击打开菜单还是权限说明。
     *
     * @param accessibilityTrusted 辅助功能是否已授权
     * @return 未授权时返回权限说明，已授权时返回菜单
     */
    static func destination(accessibilityTrusted: Bool) -> StatusClickDestination {
        accessibilityTrusted ? .menu : .permissionGuide
    }

    /**
     * 右键或按住 Control 的点击。
     *
     * 这种点击始终打开原来的菜单，不打开权限说明。
     *
     * @param rightButton 事件是右键按下或抬起
     * @param control 事件带有 Control 修饰键
     * @return 应打开菜单时返回 true
     */
    static func isAlternateClick(rightButton: Bool, control: Bool) -> Bool {
        rightButton || control
    }

    /**
     * 决定这一次点击的结果。
     *
     * 右键和 Control 点击优先打开菜单。其余点击再按授权状态选择。
     *
     * @param accessibilityTrusted 辅助功能是否已授权
     * @param alternateClick 是否为右键或 Control 点击
     * @return 菜单或权限说明
     */
    static func effect(accessibilityTrusted: Bool, alternateClick: Bool) -> StatusClickDestination {
        if alternateClick { return .menu }
        return destination(accessibilityTrusted: accessibilityTrusted)
    }
}
