import Foundation

/**
 * 一次采集是否允许入库的判断条件。
 *
 * 调用方负责填值。跳过规则集中在 PrivacyGate，采集处不再复制一套判断。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct PrivacyDecision: Equatable {
    /** 当前是否处于暂停。 */
    var isPaused: Bool
    /** 系统安全输入是否开启。 */
    var secureInputEnabled: Bool
    /** 用户是否允许在安全输入期间仍记录。默认关闭。 */
    var recordDuringSecureInput: Bool
    /** 是否忽略带机密标记的剪切板。默认开启。 */
    var ignoreConcealed: Bool
    /** 剪切板是否带机密标记。 */
    var hasConcealedMarker: Bool
    /** 剪切板是否带 org.nspasteboard.TransientType。 */
    var hasTransientMarker: Bool = false
    /** 复制发生时的前台应用 bundle id。 */
    var sourceBundleID: String?
    /** 用户排除的应用 bundle id。 */
    var excludedBundleIDs: Set<String>
    /** 是否为本应用写回剪切板引起的变化。 */
    var isSelfWrite: Bool
}

/**
 * 采集隐私门禁。
 *
 * 返回 false 表示跳过本次采集。密码类应用、机密标记、临时标记、安全输入和暂停都在这里判断。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum PrivacyGate {
    /**
     * 判断这次剪切板变化能否入库。
     *
     * 暂停、本应用写回、临时标记、未允许的安全输入、机密标记和排除应用都会拒绝。
     *
     * @param decision 本次采集的判断条件
     * @return 允许入库时返回 true
     */
    static func allowsCapture(_ decision: PrivacyDecision) -> Bool {
        if decision.isPaused { return false }
        if decision.isSelfWrite { return false }
        if decision.hasTransientMarker { return false }
        if decision.secureInputEnabled && !decision.recordDuringSecureInput { return false }
        if decision.ignoreConcealed && decision.hasConcealedMarker { return false }
        if let bundleID = decision.sourceBundleID, decision.excludedBundleIDs.contains(bundleID) {
            return false
        }
        return true
    }
}

/**
 * 首次启动预填的排除应用。
 *
 * 用户可以在隐私设置里移除。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum DefaultExclusions {
    /** 钥匙串、系统密码、1Password 和 Bitwarden。 */
    static let apps: [(bundleID: String, name: String)] = [
        ("com.apple.keychainaccess", "钥匙串访问"),
        ("com.apple.Passwords", "密码"),
        ("com.1password.1password", "1Password"),
        ("com.agilebits.onepassword7", "1Password 7"),
        ("com.bitwarden.desktop", "Bitwarden")
    ]
}
