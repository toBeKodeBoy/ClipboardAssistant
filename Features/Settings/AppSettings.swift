import AppKit
import Carbon
import Foundation

/**
 * 从设置里排除的应用。
 *
 * 命中 bundle id 时，该应用处于前台的复制不入库。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct ExcludedApp: Codable, Identifiable, Equatable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/**
 * 面板和设置窗口的外观。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.text("跟随系统", "System")
        case .light: L10n.text("浅色", "Light")
        case .dark: L10n.text("深色", "Dark")
        }
    }
    /**
     * 转成 AppKit 外观。
     *
     * @return 跟随系统时返回 nil，由窗口继承系统外观
     */
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/**
 * 回车粘贴时的默认行为。
 *
 * 只影响 PasteMode.automatic。⌘回车和 ⇧回车仍按各自的模式执行。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum PasteBehavior: String, CaseIterable, Identifiable {
    case automatic
    case copyOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: L10n.text("自动粘贴到前台应用", "Paste into the front app")
        case .copyOnly: L10n.text("只写入剪切板", "Copy only")
        }
    }
}

/**
 * 菜单「打开主面板」使用的位置。
 *
 * 全局快捷键不读这个值，始终在光标所在屏幕正中打开。没有保存过位置时，菜单也使用屏幕中心。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum PanelPlacement: String, CaseIterable, Identifiable {
    case mouse
    case center
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mouse: L10n.text("鼠标附近", "Near pointer")
        case .center: L10n.text("屏幕中心", "Screen center")
        }
    }
}

/**
 * 暂停时长。
 *
 * manual 一直暂停，直到用户恢复。另外两档到时后由 refreshPause 自动恢复。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum PauseChoice: String, CaseIterable, Identifiable {
    case manual
    case quarterHour
    case oneHour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: L10n.text("手动恢复", "Until resumed")
        case .quarterHour: L10n.text("15 分钟", "15 minutes")
        case .oneHour: L10n.text("1 小时", "1 hour")
        }
    }
}

/**
 * 持久化的用户偏好。
 *
 * 修改已发布属性会立刻写入 UserDefaults。历史数据不在这里。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
final class AppSettings: ObservableObject {
    @Published var launchAtLogin: Bool {
        didSet {
            persist(Keys.launchAtLogin, launchAtLogin)
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try LoginItemController.setEnabled(true)
                } else if LoginItemController.isEnabled {
                    try LoginItemController.setEnabled(false)
                }
            } catch {
                if launchAtLogin {
                    launchAtLogin = false
                }
            }
        }
    }
    /**
     * 外观。变更后立刻持久化，并通知已经打开的窗口。
     *
     * 初始化时的赋值不会触发 didSet。新旧值相同时只写偏好，不重复通知。
     */
    @Published var appearance: AppearanceChoice {
        didSet {
            persist(Keys.appearance, appearance.rawValue)
            if appearance != oldValue {
                onAppearanceChange?()
            }
        }
    }
    /** 外观发生变化时调用，由状态栏控制器写到主面板和设置窗口。 */
    var onAppearanceChange: (() -> Void)?
    @Published var pasteBehavior: PasteBehavior { didSet { persist(Keys.pasteBehavior, pasteBehavior.rawValue) } }
    @Published var panelPlacement: PanelPlacement { didSet { persist(Keys.panelPlacement, panelPlacement.rawValue) } }
    @Published var ignoreConcealed: Bool { didSet { persist(Keys.ignoreConcealed, ignoreConcealed) } }
    @Published var recordDuringSecureInput: Bool { didSet { persist(Keys.recordDuringSecureInput, recordDuringSecureInput) } }
    @Published var pauseChoice: PauseChoice { didSet { persist(Keys.pauseChoice, pauseChoice.rawValue) } }
    @Published var manuallyPaused: Bool { didSet { persist(Keys.manuallyPaused, manuallyPaused) } }
    @Published var pauseUntil: Date? { didSet { persist(Keys.pauseUntil, pauseUntil?.timeIntervalSince1970 ?? 0) } }
    var onRetentionChange: (() -> Void)?
    @Published var maxCount: Int { didSet { persist(Keys.maxCount, maxCount); onRetentionChange?() } }
    @Published var maxDays: Int { didSet { persist(Keys.maxDays, maxDays); onRetentionChange?() } }
    @Published var excludedApps: [ExcludedApp] { didSet { saveExcluded() } }
    @Published var hotkeyCode: Int { didSet { persist(Keys.hotkeyCode, hotkeyCode) } }
    @Published var hotkeyModifiers: Int { didSet { persist(Keys.hotkeyModifiers, hotkeyModifiers) } }
    @Published var hotkeyDisplay: String { didSet { persist(Keys.hotkeyDisplay, hotkeyDisplay) } }
    @Published var hotkeyConflict: Bool = false
    /** 暂停热键的虚拟键码。未设置时为 0，不注册。 */
    @Published var pauseHotkeyCode: Int { didSet { persist(Keys.pauseHotkeyCode, pauseHotkeyCode) } }
    /** 暂停热键的 Carbon 修饰键。未设置时为 0。 */
    @Published var pauseHotkeyModifiers: Int { didSet { persist(Keys.pauseHotkeyModifiers, pauseHotkeyModifiers) } }
    /** 暂停热键的显示文案。空字符串表示未设置。 */
    @Published var pauseHotkeyDisplay: String { didSet { persist(Keys.pauseHotkeyDisplay, pauseHotkeyDisplay) } }
    /** 暂停热键注册失败，或和打开主面板的组合相同时为 true。 */
    @Published var pauseHotkeyConflict: Bool = false
    /** 暂停状态变化时调用，由状态栏控制器重画图标。 */
    var onPauseStateChange: (() -> Void)?
    @Published var panelWidth: Double { didSet { persist(Keys.panelWidth, panelWidth) } }
    @Published var panelHeight: Double { didSet { persist(Keys.panelHeight, panelHeight) } }

    /**
     * 当前是否应跳过采集。
     *
     * 手动暂停，或定时暂停尚未到期时返回 true。
     */
    var isPaused: Bool {
        if manuallyPaused { return true }
        if let pauseUntil, pauseUntil > Date() { return true }
        return false
    }

    /**
     * 用户是否已经录制暂停热键。
     *
     * 显示文案为空时表示未设置，启动时不注册。
     */
    var pauseHotkeyIsSet: Bool {
        !pauseHotkeyDisplay.isEmpty
    }

    /**
     * 当前生效的保留策略。
     *
     * maxCount 或 maxDays 为 0 时表示该项不限制。图片容量固定为 200MB。
     */
    var retention: RetentionPolicy {
        RetentionPolicy(
            maxCount: maxCount == 0 ? nil : maxCount,
            maxAge: maxDays == 0 ? nil : TimeInterval(maxDays * 24 * 60 * 60),
            maxImageBytes: RetentionPolicy.imageCap
        )
    }

    /**
     * 从 UserDefaults 恢复偏好。
     *
     * 第一次启动时写入默认排除应用。条数默认 500，天数默认 30。打开主面板默认 ⌘⇧V，暂停热键默认不设置。
     *
     * @param defaults 偏好存储，测试可传入独立套件
     */
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        pasteBehavior = PasteBehavior(rawValue: defaults.string(forKey: Keys.pasteBehavior) ?? "") ?? .automatic
        let panelMigration = PanelGeometry.migrate(
            storedWidth: defaults.object(forKey: Keys.panelWidth) as? Double,
            storedHeight: defaults.object(forKey: Keys.panelHeight) as? Double,
            storedPlacement: defaults.string(forKey: Keys.panelPlacement),
            alreadyMigrated: defaults.bool(forKey: Keys.panelGeometryMigrated)
        )
        panelPlacement = panelMigration.preferred.placement
        ignoreConcealed = defaults.object(forKey: Keys.ignoreConcealed) as? Bool ?? true
        recordDuringSecureInput = defaults.object(forKey: Keys.recordDuringSecureInput) as? Bool ?? false
        pauseChoice = PauseChoice(rawValue: defaults.string(forKey: Keys.pauseChoice) ?? "") ?? .manual
        manuallyPaused = defaults.object(forKey: Keys.manuallyPaused) as? Bool ?? false
        let until = defaults.double(forKey: Keys.pauseUntil)
        pauseUntil = until > 0 ? Date(timeIntervalSince1970: until) : nil
        maxCount = defaults.object(forKey: Keys.maxCount) as? Int ?? 500
        maxDays = defaults.object(forKey: Keys.maxDays) as? Int ?? 30
        hotkeyCode = defaults.object(forKey: Keys.hotkeyCode) as? Int ?? Int(kVK_ANSI_V)
        hotkeyModifiers = defaults.object(forKey: Keys.hotkeyModifiers) as? Int ?? Int(cmdKey | shiftKey)
        hotkeyDisplay = defaults.string(forKey: Keys.hotkeyDisplay) ?? "⌘⇧V"
        pauseHotkeyCode = defaults.object(forKey: Keys.pauseHotkeyCode) as? Int ?? 0
        pauseHotkeyModifiers = defaults.object(forKey: Keys.pauseHotkeyModifiers) as? Int ?? 0
        pauseHotkeyDisplay = defaults.string(forKey: Keys.pauseHotkeyDisplay) ?? ""
        panelWidth = panelMigration.preferred.width
        panelHeight = panelMigration.preferred.height
        if defaults.bool(forKey: Keys.didSeedExclusions) {
            excludedApps = Self.loadExcluded(defaults)
        } else {
            excludedApps = DefaultExclusions.apps.map { ExcludedApp(bundleID: $0.bundleID, name: $0.name) }
            defaults.set(true, forKey: Keys.didSeedExclusions)
            saveExcluded()
        }
        if panelMigration.shouldPersist {
            defaults.set(panelMigration.preferred.width, forKey: Keys.panelWidth)
            defaults.set(panelMigration.preferred.height, forKey: Keys.panelHeight)
            defaults.set(panelMigration.preferred.placement.rawValue, forKey: Keys.panelPlacement)
            defaults.set(true, forKey: Keys.panelGeometryMigrated)
        }
    }

    /**
     * 定时暂停到期后清除暂停状态。
     *
     * 没有截止时间时，手动暂停保持不变。到期后通知菜单栏重画图标。
     *
     * @param notify 为 false 时只改状态，由调用方在最终状态确定后重画
     */
    func refreshPause(notify: Bool = true) {
        guard let pauseUntil, pauseUntil <= Date() else { return }
        self.pauseUntil = nil
        manuallyPaused = false
        if notify {
            onPauseStateChange?()
        }
    }

    private let defaults: UserDefaults

    /**
     * 把单个偏好写入 UserDefaults。
     *
     * @param key 偏好键
     * @param value 可被 UserDefaults 接受的值
     */
    private func persist(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    /**
     * 把排除应用列表编码进 UserDefaults。
     */
    private func saveExcluded() {
        if let data = try? JSONEncoder().encode(excludedApps) {
            defaults.set(data, forKey: Keys.excludedApps)
        }
    }

    /**
     * 读取已保存的排除应用。
     *
     * @param defaults 偏好存储
     * @return 解码后的列表；数据缺失或损坏时返回空数组
     */
    private static func loadExcluded(_ defaults: UserDefaults) -> [ExcludedApp] {
        guard let data = defaults.data(forKey: Keys.excludedApps),
              let apps = try? JSONDecoder().decode([ExcludedApp].self, from: data) else {
            return []
        }
        return apps
    }

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let appearance = "appearance"
        static let pasteBehavior = "pasteBehavior"
        static let panelPlacement = "panelPlacement"
        static let ignoreConcealed = "ignoreConcealed"
        static let recordDuringSecureInput = "recordDuringSecureInput"
        static let pauseChoice = "pauseChoice"
        static let manuallyPaused = "manuallyPaused"
        static let pauseUntil = "pauseUntil"
        static let maxCount = "maxCount"
        static let maxDays = "maxDays"
        static let excludedApps = "excludedApps"
        static let didSeedExclusions = "didSeedExclusions"
        static let hotkeyCode = "hotkeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hotkeyDisplay = "hotkeyDisplay"
        static let pauseHotkeyCode = "pauseHotkeyCode"
        static let pauseHotkeyModifiers = "pauseHotkeyModifiers"
        static let pauseHotkeyDisplay = "pauseHotkeyDisplay"
        static let panelWidth = "panelWidth"
        static let panelHeight = "panelHeight"
        static let panelGeometryMigrated = "panelGeometryMigrated"
    }
}
