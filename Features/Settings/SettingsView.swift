import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = SettingsTab.general
    @State private var recording: HotkeyRecording?
    @State private var confirmClear = false
    @State private var recordMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.allCases) { item in
                    Button(item.title) { tab = item }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(tab == item ? Color.accentColor : Color.clear)
                        .foregroundStyle(tab == item ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 160)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            Divider()
            Group {
                switch tab {
                case .general: general
                case .privacy: privacy
                case .storage: storage
                case .about: about
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 720, height: 480)
        .onAppear { model.refreshAccessibility() }
        .background(KeyRecorder(recording: $recording, message: $recordMessage, settings: model.settings, onSave: model.applyHotkey))
    }

    private var general: some View {
        Form {
            Toggle(L10n.text("开机启动", "Launch at login"), isOn: $model.settings.launchAtLogin)
                .onChange(of: model.settings.launchAtLogin) { _, enabled in
                    do {
                if enabled {
                    try LoginItemController.setEnabled(true)
                } else if LoginItemController.isEnabled {
                    try LoginItemController.setEnabled(false)
                }
            } catch {
                model.settings.launchAtLogin = false
            }
                }
            LabeledContent(L10n.text("打开主面板", "Open panel")) {
                Button(recording == .panel ? L10n.text("请按下快捷键", "Press a shortcut") : model.settings.hotkeyDisplay) {
                    recording = .panel
                }
                .foregroundStyle(model.settings.hotkeyConflict ? Color.red : Color.primary)
            }
            PauseHotkeySetting(
                settings: model.settings,
                recording: $recording,
                onClear: {
                    recording = nil
                    recordMessage = nil
                    model.clearPauseHotkey()
                }
            )
            if let recordMessage {
                Text(recordMessage).font(.caption).foregroundStyle(.red)
            }
            Picker(L10n.text("外观", "Appearance"), selection: $model.settings.appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.text("粘贴行为", "Paste behavior"), selection: $model.settings.pasteBehavior) {
                ForEach(PasteBehavior.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.text("面板位置", "Panel position"), selection: $model.settings.panelPlacement) {
                ForEach(PanelPlacement.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var privacy: some View {
        Form {
            Toggle(L10n.text("忽略机密标记", "Ignore concealed items"), isOn: $model.settings.ignoreConcealed)
            Toggle(L10n.text("安全输入时仍记录", "Record during secure input"), isOn: $model.settings.recordDuringSecureInput)
            RecordingStatusLabel(settings: model.settings)
            Picker(L10n.text("暂停时长", "Pause duration"), selection: $model.settings.pauseChoice) {
                ForEach(PauseChoice.allCases) { Text($0.title).tag($0) }
            }
            Section(L10n.text("排除应用", "Excluded apps")) {
                ForEach(model.settings.excludedApps) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Button(L10n.text("移除", "Remove")) {
                            model.settings.excludedApps.removeAll { $0.bundleID == app.bundleID }
                        }
                    }
                }
                Button(L10n.text("添加应用…", "Add app…")) { addApp() }
            }
        }
    }

    private var storage: some View {
        Form {
            Picker(L10n.text("最多保留", "Keep at most"), selection: $model.settings.maxCount) {
                Text("200").tag(200)
                Text("500").tag(500)
                Text("1000").tag(1000)
                Text(L10n.text("不限制", "No limit")).tag(0)
            }
            Picker(L10n.text("最长保留", "Keep for"), selection: $model.settings.maxDays) {
                Text(L10n.text("7 天", "7 days")).tag(7)
                Text(L10n.text("30 天", "30 days")).tag(30)
                Text(L10n.text("90 天", "90 days")).tag(90)
                Text(L10n.text("永久", "Forever")).tag(0)
            }
            LabeledContent(L10n.text("图片容量", "Image storage")) {
                Text("200 MB")
            }
            Text(L10n.text("当前 \(model.items.count) 条", "\(model.items.count) items"))
                .foregroundStyle(.secondary)
            Button(L10n.text("清空全部历史", "Clear all history"), role: .destructive) {
                confirmClear = true
            }
            .alert(L10n.text("清空全部历史？", "Clear all history?"), isPresented: $confirmClear) {
                Button(L10n.text("清空", "Clear"), role: .destructive) {
                    model.clearAllFromSettings()
                }
                Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.text("将删除 \(model.items.count) 条记录，包含已置顶的条目。", "This deletes \(model.items.count) items, including pinned ones."))
            }
            if let clearAllError = model.clearAllError {
                Text(clearAllError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: model.settings.maxCount) { _, _ in try? model.store.applyRetention(model.settings.retention); model.reload() }
        .onChange(of: model.settings.maxDays) { _, _ in try? model.store.applyRetention(model.settings.retention); model.reload() }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("剪切板助手", "Clipboard Assistant")).font(.title2)
            Text("1.0.0 (1)").foregroundStyle(.secondary)
            LabeledContent(L10n.text("辅助功能", "Accessibility")) {
                Text(model.accessibilityTrusted ? L10n.text("已授权", "Granted") : L10n.text("未授权", "Not granted"))
            }
            let counts = HistoryCounts.tally(model.items)
            LabeledContent(L10n.text("全部", "All")) {
                Text("\(counts.total)")
            }
            LabeledContent(L10n.text("置顶", "Pinned")) {
                Text("\(counts.pinned)")
            }
            ForEach(ItemKind.allCases, id: \.self) { kind in
                LabeledContent(kind.title) {
                    Text("\(counts.count(for: kind))")
                }
            }
            Button(L10n.text("打开系统设置", "Open System Settings")) {
                _ = AccessibilityClient.isTrusted(prompt: true)
                AccessibilityClient.openSettings()
            }
            Button(L10n.text("导出诊断", "Export diagnostics")) { exportDiagnostics() }
            Spacer()
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier ?? url.lastPathComponent
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        if !model.settings.excludedApps.contains(where: { $0.bundleID == bundleID }) {
            model.settings.excludedApps.append(ExcludedApp(bundleID: bundleID, name: name))
        }
    }

    private func exportDiagnostics() {
        let source = (try? model.store.fetchAll()) ?? model.items
        let counts = HistoryCounts.tally(source)
        let dbURL = model.store.directory.appendingPathComponent("history.db")
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? NSNumber)?.intValue ?? 0
        let payload: [String: Any] = [
            "version": "1.0.0",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibilityTrusted": model.accessibilityTrusted,
            "itemCount": counts.total,
            "counts": counts.diagnosticCounts,
            "databaseBytes": bytes
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.json]
        save.nameFieldStringValue = "clipboard-diagnostics.json"
        guard save.runModal() == .OK, let url = save.url else { return }
        try? data.write(to: url)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, privacy, storage, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: L10n.text("通用", "General")
        case .privacy: L10n.text("隐私", "Privacy")
        case .storage: L10n.text("存储", "Storage")
        case .about: L10n.text("关于", "About")
        }
    }
}

/**
 * 暂停热键的录制和清除。
 *
 * 直接观察偏好，清除后按钮文案会回到「未设置」。
 */
struct PauseHotkeySetting: View {
    @ObservedObject var settings: AppSettings
    @Binding var recording: HotkeyRecording?
    var onClear: () -> Void

    var body: some View {
        LabeledContent(L10n.text("暂停 / 恢复", "Pause or resume")) {
            HStack {
                Button(recording == .pause ? L10n.text("请按下快捷键", "Press a shortcut") : title) {
                    recording = .pause
                }
                .foregroundStyle(settings.pauseHotkeyConflict ? Color.red : Color.primary)
                if settings.pauseHotkeyIsSet {
                    Button(L10n.text("清除", "Clear"), action: onClear)
                }
            }
        }
    }

    /**
     * 按钮上的快捷键文案。
     *
     * 还没录制时显示「未设置」。
     */
    private var title: String {
        settings.pauseHotkeyIsSet ? settings.pauseHotkeyDisplay : L10n.text("未设置", "Not set")
    }
}

/**
 * 当前是否正在采集。
 *
 * 和菜单栏斜杠读同一套暂停状态。
 */
struct RecordingStatusLabel: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        LabeledContent(L10n.text("记录状态", "Recording")) {
            Text(settings.isPaused ? L10n.text("已暂停", "Paused") : L10n.text("正在记录", "Recording"))
        }
    }
}

/**
 * 设置页正在录制的热键。
 */
enum HotkeyRecording {
    /** 打开主面板。 */
    case panel
    /** 暂停或恢复采集。 */
    case pause
}

struct KeyRecorder: NSViewRepresentable {
    @Binding var recording: HotkeyRecording?
    @Binding var message: String?
    var settings: AppSettings
    var onSave: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(recording: $recording, message: $message, settings: settings, onSave: onSave)
    }

    final class Coordinator {
        private var recordingBinding: Binding<HotkeyRecording?>
        private var message: Binding<String?>
        private let settings: AppSettings
        private let onSave: () -> Void
        private var monitor: Any?

        init(recording: Binding<HotkeyRecording?>, message: Binding<String?>, settings: AppSettings, onSave: @escaping () -> Void) {
            self.recordingBinding = recording
            self.message = message
            self.settings = settings
            self.onSave = onSave
        }

        func install() {
            uninstall()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Coordinator.forward(self, event: event)
            }
        }

        /**
         * 把按键交给录制器。
         *
         * 录制器已经释放时原样返回事件。
         *
         * @param coordinator 当前录制器，可能已经释放
         * @param event 按键事件
         * @return 已消费时返回 nil
         */
        static func forward(_ coordinator: Coordinator?, event: NSEvent) -> NSEvent? {
            coordinator?.receive(event) ?? event
        }

        /**
         * 处理一次按键，供事件监听和测试调用。
         *
         * @param event 按键事件
         * @return 已消费时返回 nil
         */
        func receive(_ event: NSEvent) -> NSEvent? {
            handle(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers ?? "") ? nil : event
        }

        /**
         * 按当前录制目标处理一次按键。
         *
         * 没有在录制、缺少修饰键时不消费。保留键和重复组合只提示，不保存。
         *
         * @param keyCode 虚拟键码
         * @param flags 修饰键
         * @param characters 事件给出的字符；为空时用键名
         * @return 已消费时返回 true
         */
        func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String) -> Bool {
            guard let target = recordingBinding.wrappedValue else { return false }
            let modifiers = flags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) else { return false }
            if HotkeyCodec.isReserved(keyCode: keyCode, flags: modifiers) {
                message.wrappedValue = L10n.text("不能使用 ⌘C / ⌘V / ⌘X / ⌘Q", "⌘C / ⌘V / ⌘X / ⌘Q are reserved")
                return true
            }
            let code = Int(keyCode)
            let carbon = Int(HotkeyCodec.carbonModifiers(from: modifiers))
            let slot: HotkeyCenter.ID = target == .pause ? .pause : .panel
            if HotkeyPlan.duplicates(
                recording: slot,
                code: code,
                modifiers: carbon,
                panelCode: settings.hotkeyCode,
                panelModifiers: settings.hotkeyModifiers,
                pauseCode: settings.pauseHotkeyCode,
                pauseModifiers: settings.pauseHotkeyModifiers,
                pauseIsSet: settings.pauseHotkeyIsSet
            ) {
                message.wrappedValue = L10n.text("不能和另一组快捷键相同", "This shortcut is already used")
                return true
            }
            let display = HotkeyCodec.display(keyCode: keyCode, flags: modifiers, fallback: characters)
            switch target {
            case .panel:
                settings.hotkeyCode = code
                settings.hotkeyModifiers = carbon
                settings.hotkeyDisplay = display
            case .pause:
                settings.pauseHotkeyCode = code
                settings.pauseHotkeyModifiers = carbon
                settings.pauseHotkeyDisplay = display
            }
            recordingBinding.wrappedValue = nil
            message.wrappedValue = nil
            onSave()
            return true
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
