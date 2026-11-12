import AppKit

/**
 * 应用入口委托。
 *
 * 菜单栏应用，无 Dock 图标。数据库打不开时提示一次，本次启动不记录历史。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var panel: PanelController?
    private var status: StatusItemController?

    /**
     * 启动菜单栏、历史库和主面板。
     *
     * 单元测试进程在切到 accessory 后立即返回，不打开数据库。
     *
     * @param notification 系统启动通知
     */
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard !AppRuntime.skipsLaunch else { return }
        do {
            try MainActor.assumeIsolated {
                try self.launch(directory: try AppRuntime.supportDirectory())
            }
        } catch {
            Self.presentDatabaseFailure(error)
        }
    }

    /**
     * 告诉用户这次没有开始记录历史。
     *
     * 测试可在弹出前关掉模态，避免对话框停住测试进程。
     *
     * @param error 打开数据库的错误，只写入日志
     */
    static func presentDatabaseFailure(_ error: Error) {
        AppLog.store.error("database open failed \(String(describing: error))")
        let alert = NSAlert()
        alert.messageText = L10n.text("无法打开历史数据库", "Couldn't open history database")
        alert.informativeText = L10n.text("剪切板助手这次没有记录历史。", "Clipboard Assistant won't record history this launch.")
        alert.runModal()
    }

    /**
     * 打开历史库并装上面板和菜单栏。
     *
     * 测试传入临时目录和假热键，避免写到用户的历史并占用全局快捷键。
     *
     * @param directory 历史库目录
     * @param settings 用户偏好
     * @param hotkeys 热键登记，为空时使用系统热键
     * @return 已启动的应用状态
     * @throws 数据库打不开时抛出
     */
    @MainActor
    @discardableResult
    func launch(directory: URL, settings: AppSettings = AppSettings(), hotkeys: GlobalHotkeys? = nil) throws -> AppModel {
        AppLog.store.info("launch")
        let store = try HistoryStore(directory: directory)
        let model = AppModel(store: store, settings: settings)
        if let hotkeys {
            model.hotkeys = hotkeys
        }
        let panel = PanelController(model: model)
        let status = StatusItemController(model: model, panel: panel)
        model.start()
        self.model = model
        self.panel = panel
        self.status = status
        AppLog.store.info("launch ready")
        return model
    }
}

/**
 * 区分正常启动和单元测试。
 *
 * 测试进程不创建菜单栏，避免测试挂住。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum AppRuntime {
    /**
     * 当前进程是否由 XCTest 启动。
     *
     * @return 存在 XCTestConfigurationFilePath 时返回 true
     */
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /**
     * 为 true 时启动只切到菜单栏模式，不打开用户的历史库。
     *
     * 测试进程默认跳过。需要覆盖启动失败提示时，测试可以暂时关掉。
     */
    static var skipsLaunch: Bool = isRunningTests

    /**
     * 历史库目录。测试可换成打不开的路径。
     */
    static var supportDirectory: () throws -> URL = { try AppPaths.supportDirectory() }
}

/**
 * 程序入口。
 *
 * 持有 AppDelegate，避免运行循环期间被释放。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
@main
enum ClipboardAssistantMain {
    /**
     * 创建应用并进入运行循环。
     */
    static func main() {
        #if DEBUG
        if ArchiveCrashHarness.runIfRequested(CommandLine.arguments) { return }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}
