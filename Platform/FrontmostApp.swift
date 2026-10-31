import AppKit
import Carbon
import Foundation

/**
 * 前台应用。
 *
 * 读取身份不需要辅助功能。打开面板时记下返回值，作为这次粘贴的目标。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum FrontmostApp {
    /**
     * 读取当前前台应用。
     *
     * @return bundle id 和应用显示名。没有前台应用时名称为「未知应用」
     */
    static func current() -> (bundleID: String?, name: String) {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? L10n.text("未知应用", "Unknown App")
        return (app?.bundleIdentifier, name)
    }

    /**
     * 按 bundle id 查找正在运行的应用。
     *
     * @param bundleID 目标应用标识，为空时直接返回 nil
     * @return 第一个匹配的运行实例
     */
    static func runningApplication(bundleID: String?) -> NSRunningApplication? {
        guard let bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
}

/**
 * 来源应用图标缓存。
 *
 * 按 bundle id 查找并缓存。应用已卸载或没有 bundle id 时返回通用应用符号。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum AppIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private static let fallback: NSImage = {
        let image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /**
     * 取来源应用图标。
     *
     * @param bundleID 应用标识，空或找不到应用时使用通用符号
     * @return 32 点图标，结果会缓存
     */
    static func image(bundleID: String?) -> NSImage {
        let key = (bundleID ?? "") as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = load(bundleID: bundleID) ?? fallback
        cache.setObject(image, forKey: key)
        return image
    }

    /**
     * 从已安装应用读取图标。
     *
     * @param bundleID 应用标识
     * @return 应用图标；应用不存在时返回 nil
     */
    private static func load(bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }
}

/**
 * 系统安全输入状态。
 *
 * 密码框会打开安全输入。采集在它开启期间，以及结束后 1 秒内跳过。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum SecureInput {
    /**
     * 查询安全输入是否开启。
     *
     * @return IsSecureEventInputEnabled 为真时返回 true
     */
    static func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }
}
