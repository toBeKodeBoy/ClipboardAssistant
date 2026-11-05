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
}
