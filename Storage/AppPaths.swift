import Foundation

enum AppPaths {
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

enum StoreError: Error, Equatable {
    case open(String)
    case sql(String)
}

struct StoredRepresentation: Equatable {
    var uti: String
    var storage: String
    var relativePath: String?
    var inlineValue: String?
}
