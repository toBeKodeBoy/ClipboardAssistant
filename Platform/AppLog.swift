import Foundation
import os

enum AppLog {
    static let capture = Channel(category: "capture")
    static let paste = Channel(category: "paste")
    static let store = Channel(category: "store")

    struct Channel {
        let category: String
        private let unified: Logger

        init(category: String) {
            self.category = category
            unified = Logger(subsystem: "ClipboardAssistant", category: category)
        }

        func info(_ message: String) {
            DailyLog.shared.write(level: "info", category: category, message: message)
            unified.info("\(message, privacy: .public)")
        }

        func error(_ message: String) {
            DailyLog.shared.write(level: "error", category: category, message: message)
            unified.error("\(message, privacy: .private)")
        }
    }
}

final class DailyLog: @unchecked Sendable {
    static let shared = DailyLog(directory: nil)
    static let retentionDays = 14

    private let queue = DispatchQueue(label: "ClipboardAssistant.log")
    private let fileManager: FileManager
    private let directoryOverride: URL?
    private let calendar: Calendar
    private let retentionDays: Int
    private let dayFormatter: DateFormatter
    private let timestampFormatter: DateFormatter
    private var handle: FileHandle?
    private var openDay: String?

    init(directory: URL?, fileManager: FileManager = .default, calendar: Calendar = .current, retentionDays: Int = DailyLog.retentionDays) {
        directoryOverride = directory
        self.fileManager = fileManager
        self.calendar = calendar
        self.retentionDays = retentionDays
        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.calendar = calendar
        timestampFormatter.timeZone = calendar.timeZone
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func write(level: String, category: String, message: String, now: Date = Date()) {
        queue.sync {
            append(level: level, category: category, message: message, now: now)
        }
    }

    private func append(level: String, category: String, message: String, now: Date) {
        let day = dayFormatter.string(from: now)
        if openDay != day || handle == nil {
            reopen(day: day, now: now)
        }
        let text = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(timestampFormatter.string(from: now)) \(level) \(category) \(text)\n"
        handle?.write(Data(line.utf8))
    }

    private func reopen(day: String, now: Date) {
        handle?.closeFile()
        handle = nil
        openDay = nil
        guard let directory = resolvedDirectory() else { return }
        let url = directory.appendingPathComponent("clipboard-\(day).log")
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return }
        _ = try? opened.seekToEnd()
        handle = opened
        openDay = day
        prune(in: directory, now: now)
    }

    private func resolvedDirectory() -> URL? {
        if let directoryOverride { return directoryOverride }
        return try? AppPaths.logsDirectory(fileManager: fileManager)
    }

    private func prune(in directory: URL, now: Date) {
        guard retentionDays > 0,
              let cutoff = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: calendar.startOfDay(for: now)),
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            guard let day = Self.day(in: name),
                  let date = dayFormatter.date(from: day),
                  date < cutoff else { continue }
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func day(in fileName: String) -> String? {
        guard fileName.hasPrefix("clipboard-"), fileName.hasSuffix(".log") else { return nil }
        let day = fileName.dropFirst("clipboard-".count).dropLast(".log".count)
        guard day.count == 10 else { return nil }
        return String(day)
    }
}
