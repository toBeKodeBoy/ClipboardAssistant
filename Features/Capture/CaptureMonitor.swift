import AppKit
import Foundation

/**
 * 剪切板采集监视器。
 *
 * 在主线程每 400ms 检查 changeCount。命中后把解码和建条目放到串行队列，完成后再回到主线程回调。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
final class CaptureMonitor {
    /**
     * 采集成功后的回调。
     *
     * 参数依次为条目、来源 bundle id、来源显示名。在主线程调用。
     */
    var onCaptured: ((CapturedClipboard, String?, String) -> Void)?

    /** 轮询计时器。 */
    private var timer: Timer?
    /** 上次观察到的 changeCount。 */
    private var lastChangeCount: Int
    /** 本应用写回剪切板后应忽略的 changeCount。 */
    private var ignoredCounts = Set<Int>()
    /** 最近一次检测到安全输入的时间，用于结束后 1 秒内继续跳过。 */
    private var lastSecureInputAt: Date?
    /** 解码和建条目使用的串行队列。 */
    private let queue = DispatchQueue(label: "ClipboardAssistant.capture")
    /** 当前偏好。暂停、排除应用和安全输入开关都从这里读。 */
    private weak var settings: AppSettings?

    /**
     * 记下当前 changeCount，避免启动时把已有剪切板再记一条。
     *
     * @param pasteboard 要监视的剪切板，默认是系统通用剪切板
     */
    init(pasteboard: NSPasteboard = .general) {
        lastChangeCount = pasteboard.changeCount
    }

    /**
     * 开始每 400ms 轮询。
     *
     * 重复调用会先停掉上一个计时器。
     *
     * @param settings 采集时读取的偏好
     */
    func start(settings: AppSettings) {
        self.settings = settings
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /**
     * 停止轮询。
     */
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /**
     * 忽略本应用自己写入引起的下一次变化。
     *
     * @param count 写入后的 changeCount
     */
    func ignoreChangeCount(_ count: Int) {
        ignoredCounts.insert(count)
    }

    /**
     * 检查一次剪切板是否变化，并在允许时采集。
     *
     * 暂停、本应用、安全输入及其结束后 1 秒、隐私门禁拒绝的内容都跳过。
     */
    private func poll() {
        guard let settings else { return }
        settings.refreshPause()
        if SecureInput.isEnabled() {
            lastSecureInputAt = Date()
        }
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if ignoredCounts.remove(count) != nil {
            AppLog.capture.info("skip self-write")
            return
        }
        let front = FrontmostApp.current()
        let secureNow = SecureInput.isEnabled()
        let secureSticky = !settings.recordDuringSecureInput
            && lastSecureInputAt.map { Date().timeIntervalSince($0) < 1 } == true
        if settings.isPaused {
            AppLog.capture.info("skip paused")
            return
        }
        if front.bundleID == Bundle.main.bundleIdentifier {
            AppLog.capture.info("skip self")
            return
        }
        if (secureNow || secureSticky) && !settings.recordDuringSecureInput {
            AppLog.capture.info("skip secure-input")
            return
        }
        let snapshot = PasteboardReader.snapshot(pasteboard)
        let decision = PrivacyDecision(
            isPaused: false,
            secureInputEnabled: false,
            recordDuringSecureInput: settings.recordDuringSecureInput,
            ignoreConcealed: settings.ignoreConcealed,
            hasConcealedMarker: snapshot.hasConcealedMarker,
            hasTransientMarker: snapshot.hasTransientMarker,
            sourceBundleID: front.bundleID,
            excludedBundleIDs: Set(settings.excludedApps.map(\.bundleID)),
            isSelfWrite: false
        )
        guard PrivacyGate.allowsCapture(decision) else {
            logSkipped(snapshot, frontBundleID: front.bundleID, settings: settings)
            return
        }
        queue.async {
            guard let captured = CaptureBuilder.build(snapshot) else {
                AppLog.capture.info("skip empty")
                return
            }
            let kind = captured.kind.rawValue
            let oversize = captured.oversize
            let bytes = captured.byteSize
            AppLog.capture.info("captured kind=\(kind) oversize=\(oversize) bytes=\(bytes)")
            let sourceName = snapshot.hasRemoteMarker ? L10n.text("通用剪贴板", "Universal Clipboard") : front.name
            DispatchQueue.main.async { [weak self] in
                self?.onCaptured?(captured, front.bundleID, sourceName)
            }
        }
    }

    /**
     * 记录被隐私门禁拒绝的原因。
     *
     * 日志只写原因和 bundle id，不写剪切板正文。
     *
     * @param snapshot 被拒绝的快照
     * @param frontBundleID 当时的前台应用
     * @param settings 当前偏好
     */
    private func logSkipped(_ snapshot: PasteboardSnapshot, frontBundleID: String?, settings: AppSettings) {
        if snapshot.hasTransientMarker {
            AppLog.capture.info("skip transient")
        } else if settings.ignoreConcealed, snapshot.hasConcealedMarker {
            AppLog.capture.info("skip concealed")
        } else if let frontBundleID {
            AppLog.capture.info("skip excluded \(frontBundleID)")
        } else {
            AppLog.capture.info("skip privacy")
        }
    }
}

/**
 * 从系统剪切板读取采集所需的类型。
 *
 * 超限内容先对原文计算哈希，再只把预览放进快照。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum PasteboardReader {
    /**
     * 读取剪切板上需要的类型。
     *
     * 标记类型无论大小都保留。图片超限时不保留预览字节，只保留全文哈希和字节数。
     *
     * @param pasteboard 系统剪切板
     * @param limits 单条大小上限
     * @return 供建条目使用的快照
     */
    static func snapshot(_ pasteboard: NSPasteboard, limits: CaptureLimits = CaptureLimits()) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [String: Data] = [:]
            var digests: [String: String] = [:]
            var counts: [String: Int] = [:]
            for type in item.types {
                let raw = type.rawValue
                if PasteboardUTI.markers.contains(raw) {
                    values[raw] = item.data(forType: type) ?? Data()
                    continue
                }
                guard PasteboardUTI.captured.contains(raw), let data = item.data(forType: type) else { continue }
                let cap = limit(for: raw, limits: limits)
                if data.count > cap {
                    digests[raw] = ContentHash.sha256(data)
                    counts[raw] = data.count
                    if !PasteboardUTI.imageTypes.contains(raw) {
                        values[raw] = Data(data.prefix(limits.previewBytes))
                    }
                } else {
                    values[raw] = data
                }
            }
            return PasteboardItemData(values: values, fullDigests: digests, fullByteCounts: counts)
        }
        return PasteboardSnapshot(items: items)
    }

    /**
     * 返回某一类型的单条字节上限。
     *
     * @param uti 剪切板类型
     * @param limits 采集上限
     * @return 该类型允许读入快照的最大字节数
     */
    private static func limit(for uti: String, limits: CaptureLimits) -> Int {
        if PasteboardUTI.imageTypes.contains(uti) { return limits.maxImageBytes }
        if uti == PasteboardUTI.fileURL || uti == PasteboardUTI.filenames { return 1_048_576 }
        return limits.maxTextBytes
    }
}
