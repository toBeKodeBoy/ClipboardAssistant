import Foundation
import os

/**
 * 应用日志入口。
 *
 * 同时写入统一日志和按日滚动的文本文件。调用方不得把剪切板正文传进来。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum AppLog {
    /** 采集日志。 */
    static let capture = Channel(category: "capture")
    /** 粘贴日志。 */
    static let paste = Channel(category: "paste")
    /** 存储和启动日志。 */
    static let store = Channel(category: "store")

    /**
     * 一个日志分类。
     *
     * info 对统一日志公开，error 标记为私有，避免系统日志收集错误细节。
     */
    struct Channel {
        let category: String
        private let unified: Logger

        /**
         * 创建指定分类的日志通道。
         *
         * @param category 分类名，例如 capture、paste、store
         */
        init(category: String) {
            self.category = category
            unified = Logger(subsystem: "ClipboardAssistant", category: category)
        }

        /**
         * 写一条信息日志。
         *
         * @param message 不含剪切板正文的说明
         */
        func info(_ message: String) {
            DailyLog.shared.write(level: "info", category: category, message: message)
            unified.info("\(message, privacy: .public)")
        }

        /**
         * 写一条错误日志。
         *
         * @param message 不含剪切板正文的错误说明
         */
        func error(_ message: String) {
            DailyLog.shared.write(level: "error", category: category, message: message)
            unified.error("\(message, privacy: .private)")
        }
    }
}

/**
 * 按日追加的文本日志。
 *
 * 文件名形如 clipboard-yyyy-MM-dd.log，超过保留天数的旧文件在跨天打开时删除。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
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

    /**
     * 创建按日日志。
     *
     * @param directory 日志目录。nil 时在写入时再解析 AppPaths.logsDirectory
     * @param fileManager 文件管理器
     * @param calendar 计算日期和保留窗口的日历
     * @param retentionDays 保留天数，含当天
     */
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

    /**
     * 追加一行日志。
     *
     * 换行会被替换成空格。写入在专用队列上串行执行。
     *
     * @param level 级别，例如 info 或 error
     * @param category 分类
     * @param message 日志正文，不得包含剪切板内容
     * @param now 写入时间，同时决定落到哪一天的文件
     */
    func write(level: String, category: String, message: String, now: Date = Date()) {
        queue.sync {
            append(level: level, category: category, message: message, now: now)
        }
    }

    /**
     * 在队列内追加一行，并在跨天时切换文件。
     *
     * @param level 级别
     * @param category 分类
     * @param message 已由调用方保证不含正文秘密的消息
     * @param now 写入时间
     */
    private func append(level: String, category: String, message: String, now: Date) {
        let day = dayFormatter.string(from: now)
        if openDay != day || handle == nil {
            reopen(day: day, now: now)
        }
        let text = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(timestampFormatter.string(from: now)) \(level) \(category) \(text)\n"
        handle?.write(Data(line.utf8))
    }

    /**
     * 关闭旧文件并打开当天的日志。
     *
     * 打开成功后删除超出保留天数的旧文件。
     *
     * @param day yyyy-MM-dd
     * @param now 用于计算保留窗口的当前时间
     */
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

    /**
     * 解析实际写入目录。
     *
     * @return 构造时指定的目录，或系统日志目录；两者都不可用时返回 nil
     */
    private func resolvedDirectory() -> URL? {
        if let directoryOverride { return directoryOverride }
        return try? AppPaths.logsDirectory(fileManager: fileManager)
    }

    /**
     * 删除早于保留窗口的日志文件。
     *
     * @param directory 日志目录
     * @param now 当前时间
     */
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

    /**
     * 从日志文件名取出日期。
     *
     * @param fileName 文件名，需匹配 clipboard-yyyy-MM-dd.log
     * @return 日期字符串；文件名不符合时返回 nil
     */
    private static func day(in fileName: String) -> String? {
        guard fileName.hasPrefix("clipboard-"), fileName.hasSuffix(".log") else { return nil }
        let day = fileName.dropFirst("clipboard-".count).dropLast(".log".count)
        guard day.count == 10 else { return nil }
        return String(day)
    }
}
