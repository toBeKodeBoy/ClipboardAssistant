import AppKit
import Foundation

final class CaptureMonitor {
    var onCaptured: ((CapturedClipboard, String?, String) -> Void)?

    private var timer: Timer?
    private var lastChangeCount: Int
    private var ignoredCounts = Set<Int>()
    private var lastSecureInputAt: Date?
    private let queue = DispatchQueue(label: "ClipboardAssistant.capture")
    private weak var settings: AppSettings?

    init(pasteboard: NSPasteboard = .general) {
        lastChangeCount = pasteboard.changeCount
    }

    func start(settings: AppSettings) {
        self.settings = settings
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func ignoreChangeCount(_ count: Int) {
        ignoredCounts.insert(count)
    }

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

enum PasteboardReader {
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

    private static func limit(for uti: String, limits: CaptureLimits) -> Int {
        if PasteboardUTI.imageTypes.contains(uti) { return limits.maxImageBytes }
        if uti == PasteboardUTI.fileURL || uti == PasteboardUTI.filenames { return 1_048_576 }
        return limits.maxTextBytes
    }
}
