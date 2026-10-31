import Foundation
import ServiceManagement

/**
 * 登录项。
 *
 * 使用 SMAppService.mainApp。默认关闭，由设置页切换。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum LoginItemController {
    /**
     * 注册或取消开机启动。
     *
     * @param enabled true 为注册，false 为取消
     * @throws 系统拒绝注册或取消时抛出
     */
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /**
     * 当前登录项是否已启用。
     *
     * @return 状态为 enabled 时返回 true
     */
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
