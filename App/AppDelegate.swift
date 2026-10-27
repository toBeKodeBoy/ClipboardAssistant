import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var panel: PanelController?
    private var status: StatusItemController?

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

enum AppRuntime {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@main
enum ClipboardAssistantMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}
