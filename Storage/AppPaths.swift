import Foundation

/**
 * 本机数据目录。
 *
 * 历史和日志都只写在用户本机，不上传。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum AppPaths {
    /**
     * 返回并创建应用支持目录。
     *
     * 历史数据库和负载文件放在这里。
     *
     * @param fileManager 文件管理器
     * @return ~/Library/Application Support/ClipboardAssistant/
     * @throws 无法定位或创建目录时抛出
     */
    static func supportDirectory(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("ClipboardAssistant", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /**
     * 返回并创建日志目录。
     *
     * Info.plist 配置了 ProjectLogsDirectory 时使用该目录，否则使用系统 Logs 目录。
     *
     * @param fileManager 文件管理器
     * @return 日志目录
     * @throws 无法定位或创建目录时抛出
     */
    static func logsDirectory(fileManager: FileManager = .default) throws -> URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "ProjectLogsDirectory") as? String
        let directory: URL
        if let configured, !configured.isEmpty, !configured.contains("$(") {
            directory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            let root = try fileManager.url(
                for: .libraryDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = root.appendingPathComponent("Logs/ClipboardAssistant", isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/**
 * 存储层错误。
 *
 * 打开失败和 SQL 失败分开，便于界面提示清空或删除没有成功。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum StoreError: Error, Equatable {
    /** 数据库文件无法打开。关联值是 sqlite3 错误文本。 */
    case open(String)
    /** SQL 准备或执行失败。关联值是 sqlite3 错误文本。 */
    case sql(String)
}

/**
 * 数据库中的一种剪切板负载。
 *
 * storage 为 file 时读 relativePath，为 inline 时读 inlineValue。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
struct StoredRepresentation: Equatable {
    /** 剪切板类型标识。 */
    var uti: String
    /** 存储方式，file 或 inline。 */
    var storage: String
    /** 相对应用支持目录的文件路径。inline 时为空。 */
    var relativePath: String?
    /** 直接存在数据库里的短文本，例如文件路径列表。 */
    var inlineValue: String?
}
