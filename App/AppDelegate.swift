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
        guard !AppRuntime.isRunningTests else { return }
        AppLog.store.info("launch")
        do {
            let directory = try AppPaths.supportDirectory()
            let store = try HistoryStore(directory: directory)
            let settings = AppSettings()
            let model = AppModel(store: store, settings: settings)
            let panel = PanelController(model: model)
            let status = StatusItemController(model: model, panel: panel)
            model.start()
            self.model = model
            self.panel = panel
            self.status = status
            AppLog.store.info("launch ready")
        } catch {
            AppLog.store.error("database open failed \(String(describing: error))")
            let alert = NSAlert()
            alert.messageText = L10n.text("无法打开历史数据库", "Couldn't open history database")
            alert.informativeText = L10n.text("剪切板助手这次没有记录历史。", "Clipboard Assistant won't record history this launch.")
            alert.runModal()
        }
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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}
