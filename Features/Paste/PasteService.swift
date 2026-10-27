import AppKit
import Foundation

enum PasteMode {
    case automatic
    case copyOnly
    case plainText
    case plainCopy

    var writesPlainText: Bool {
        self == .plainText || self == .plainCopy
    }

    var sendsKeystroke: Bool {
        self == .automatic || self == .plainText
    }

    var logName: String {
        switch self {
        case .automatic: "automatic"
        case .copyOnly: "copyOnly"
        case .plainText: "plainText"
        case .plainCopy: "plainCopy"
        }
    }
}

struct PasteOutcome: Equatable {
    var wroteClipboard: Bool
    var sentKeystroke: Bool
    var message: String?
}

enum PasteboardWriter {
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

    static func plainHash(for item: ClipboardItem) -> String {
        ContentHash.text(item.plainText)
    }

    private static func fileURLs(in representations: [StoredRepresentation]) -> [URL] {
        representations.compactMap { representation -> [URL]? in
            guard representation.uti == PasteboardUTI.fileURL, let inline = representation.inlineValue else { return nil }
            return inline.split(separator: "\n").map(String.init).map { URL(fileURLWithPath: $0) }
        }.flatMap { $0 }
    }
}

@MainActor
final class PasteService {
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
