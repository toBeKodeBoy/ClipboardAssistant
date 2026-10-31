import AppKit
import Foundation

/**
 * 一次粘贴或复制要怎么写回剪切板。
 *
 * plainCopy 只写入剪切板。automatic 和 plainText 还会向目标应用发送 ⌘V。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum PasteMode {
    /** 按原始类型写回，并发送 ⌘V。通用设置选「只写入剪切板」时会被改成 copyOnly。 */
    case automatic
    /** 按原始类型写回，不发送按键。 */
    case copyOnly
    /** 只写纯文本，并发送 ⌘V。 */
    case plainText
    /** 只写纯文本，不发送按键。 */
    case plainCopy

    /**
     * 是否只写入纯文本。
     *
     * @return plainText 和 plainCopy 返回 true
     */
    var writesPlainText: Bool {
        self == .plainText || self == .plainCopy
    }

    /**
     * 是否向目标应用发送 ⌘V。
     *
     * @return automatic 和 plainText 返回 true
     */
    var sendsKeystroke: Bool {
        self == .automatic || self == .plainText
    }

    /**
     * 日志里使用的模式名。
     *
     * @return 不含剪切板正文的模式标识
     */
    var logName: String {
        switch self {
        case .automatic: "automatic"
        case .copyOnly: "copyOnly"
        case .plainText: "plainText"
        case .plainCopy: "plainCopy"
        }
    }
}

/**
 * 一次粘贴的结果。
 *
 * message 非空时界面应重新打开面板并展示该提示。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct PasteOutcome: Equatable {
    /** 是否已把内容写入剪切板。超限条目为 false。 */
    var wroteClipboard: Bool
    /** 是否已发出 ⌘V。 */
    var sentKeystroke: Bool
    /** 需要展示给用户的失败原因。成功时为空。 */
    var message: String?
}

/**
 * 把历史条目写回系统剪切板。
 *
 * 不发送按键，也不激活其他应用。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum PasteboardWriter {
    /**
     * 按模式写入剪切板。
     *
     * 超限条目不改写剪切板，并返回写入前的 changeCount。文件条目写文件 URL，供目标应用按复制语义粘贴。
     *
     * @param item 要写回的历史条目
     * @param representations 该条目已保存的负载
     * @param directory 负载文件所在目录
     * @param mode 写入模式
     * @param pasteboard 目标剪切板，默认是系统通用剪切板
     * @return 写入后的 changeCount；未写入时返回写入前的值
     */
    static func write(item: ClipboardItem, representations: [StoredRepresentation], directory: URL, mode: PasteMode, pasteboard: NSPasteboard = .general) -> Int {
        let previous = pasteboard.changeCount
        if item.payloadOversize {
            return previous
        }
        pasteboard.clearContents()
        if mode.writesPlainText || item.kind == .file && representations.allSatisfy({ $0.uti == PasteboardUTI.fileURL }) && !mode.writesPlainText {
            if item.kind == .file && !mode.writesPlainText {
                let urls = fileURLs(in: representations)
                if !urls.isEmpty {
                    pasteboard.writeObjects(urls as [NSURL])
                    return max(pasteboard.changeCount, previous)
                }
            }
        }
        if mode.writesPlainText {
            pasteboard.setString(item.plainText, forType: .string)
            return pasteboard.changeCount
        }
        let entry = NSPasteboardItem()
        for representation in representations {
            if representation.uti == PasteboardUTI.fileURL, let inline = representation.inlineValue {
                entry.setString(inline, forType: NSPasteboard.PasteboardType(representation.uti))
                continue
            }
            if let path = representation.relativePath, let data = try? Data(contentsOf: directory.appendingPathComponent(path)) {
                entry.setData(data, forType: NSPasteboard.PasteboardType(representation.uti))
            } else if let inline = representation.inlineValue {
                entry.setString(inline, forType: NSPasteboard.PasteboardType(representation.uti))
            }
        }
        if entry.types.isEmpty {
            pasteboard.setString(item.plainText, forType: .string)
        } else {
            pasteboard.writeObjects([entry])
        }
        let urls = fileURLs(in: representations)
        if item.kind == .file, !urls.isEmpty {
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        }
        return pasteboard.changeCount
    }

    /**
     * 计算纯文本粘贴使用的哈希。
     *
     * @param item 历史条目
     * @return 规范化纯文本的 SHA-256
     */
    static func plainHash(for item: ClipboardItem) -> String {
        ContentHash.text(item.plainText)
    }

    /**
     * 从负载中解析文件 URL。
     *
     * @param representations 已保存的负载
     * @return 文件 URL。路径按行存放在 file URL 的 inlineValue 中
     */
    private static func fileURLs(in representations: [StoredRepresentation]) -> [URL] {
        representations.compactMap { representation -> [URL]? in
            guard representation.uti == PasteboardUTI.fileURL, let inline = representation.inlineValue else { return nil }
            return inline.split(separator: "\n").map(String.init).map { URL(fileURLWithPath: $0) }
        }.flatMap { $0 }
    }
}

/**
 * 把选中历史粘贴回打开面板时记下的前台应用。
 *
 * 先关闭面板，再写剪切板，需要按键时再激活原应用并发送 ⌘V。失败时保留已写入的剪切板内容。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
@MainActor
final class PasteService {
    /**
     * 执行一次复制或粘贴。
     *
     * 超限条目不写剪切板。未授权辅助功能或按键发送失败时，通过 completion 带回手动粘贴提示。
     *
     * @param item 选中的历史条目
     * @param representations 该条目的负载
     * @param directory 负载文件目录
     * @param mode 用户选择的粘贴模式
     * @param targetBundleID 打开面板时记下的前台应用
     * @param behavior 通用设置里的粘贴行为。为只复制时，automatic 改为 copyOnly
     * @param noteChangeCount 把本次写入的 changeCount 交给采集器忽略
     * @param prepareForKeystroke 发送按键前的准备，调用方在这里关闭面板
     * @param completion 写完或发送按键后的结果，可能晚于本方法返回
     */
    func perform(
        item: ClipboardItem,
        representations: [StoredRepresentation],
        directory: URL,
        mode: PasteMode,
        targetBundleID: String?,
        behavior: PasteBehavior,
        noteChangeCount: (Int) -> Void,
        prepareForKeystroke: () -> Void = {},
        completion: @escaping (PasteOutcome) -> Void
    ) {
        if item.payloadOversize {
            AppLog.paste.info("paste skipped oversize")
            completion(PasteOutcome(wroteClipboard: false, sentKeystroke: false, message: L10n.text("内容过大未保存", "Content was too large to save")))
            return
        }
        let effective: PasteMode = behavior == .copyOnly && mode == .automatic ? .copyOnly : mode
        let count = PasteboardWriter.write(item: item, representations: representations, directory: directory, mode: effective)
        noteChangeCount(count)
        let modeName = effective.logName
        let kind = item.kind.rawValue
        guard effective.sendsKeystroke else {
            AppLog.paste.info("paste copied mode=\(modeName) kind=\(kind)")
            completion(PasteOutcome(wroteClipboard: true, sentKeystroke: false, message: nil))
            return
        }
        guard AccessibilityClient.isTrusted() else {
            AppLog.paste.error("paste copied without keystroke mode=\(modeName)")
            completion(PasteOutcome(
                wroteClipboard: true,
                sentKeystroke: false,
                message: L10n.text("未能自动粘贴，已复制，请手动粘贴", "Couldn't paste automatically. Copied — paste it yourself.")
            ))
            return
        }
        prepareForKeystroke()
        FrontmostApp.runningApplication(bundleID: targetBundleID)?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let sent = KeystrokeSender.sendCommandV()
            if sent {
                AppLog.paste.info("paste keystroke sent mode=\(modeName) kind=\(kind)")
            } else {
                AppLog.paste.error("paste keystroke failed mode=\(modeName)")
            }
            completion(PasteOutcome(
                wroteClipboard: true,
                sentKeystroke: sent,
                message: sent ? nil : L10n.text("未能自动粘贴，已复制，请手动粘贴", "Couldn't paste automatically. Copied — paste it yourself.")
            ))
        }
    }
}
