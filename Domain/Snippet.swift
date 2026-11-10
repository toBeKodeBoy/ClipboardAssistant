import Foundation

struct SnippetVariable: Codable, Equatable, Identifiable {
    var name: String
    var label: String = ""
    var required: Bool = true
    var multiline: Bool = false
    var id: String { name }
    var displayName: String { label.isEmpty ? name : label }
}

struct SnippetGroup: Identifiable, Equatable {
    var id: String
    var name: String
}

/// A manually saved text template, independent of clipboard history and retention.
struct Snippet: Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
    var body: String
    var groupID: String? = nil
    var keyword: String = ""
    var variables: [SnippetVariable] = []
    var createdAt = Date()
    /// distantPast denotes a draft that has never been persisted.
    var updatedAt = Date.distantPast

    func validated() throws -> Snippet {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(result.title.count), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.contains("\0"), !body.contains("\0"), !keyword.contains("\0") else {
            throw SnippetError.invalidContent
        }
        guard result.keyword.isEmpty || result.keyword.range(of: "^;[A-Za-z][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
            throw SnippetError.invalidKeyword
        }
        let parsed = try SnippetTemplate.parse(body)
        result.variables = parsed.names.map { name in variables.first { $0.name == name } ?? SnippetVariable(name: name) }
        guard result.variables.allSatisfy({ $0.label.count <= 80 && !$0.label.contains("\0") }) else {
            throw SnippetError.invalidContent
        }
        return result
    }

    /// nil selects all groups; an empty identifier selects ungrouped snippets.
    func matches(query: String, groupID: String?) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix(";") { return !keyword.isEmpty && keyword.lowercased() == q.lowercased() }
        guard groupID == nil || (self.groupID ?? "") == groupID else { return false }
        return q.isEmpty || [title, body, keyword].contains { $0.range(of: q, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil }
    }
}

enum SnippetError: Error, LocalizedError, Equatable {
    case invalidContent, invalidKeyword, invalidTemplate, tooLarge, requiredValue, conflict, storage, futureVersion, invalidGroup

    var errorDescription: String? {
        switch self {
        case .invalidContent: return L10n.text("请检查标题、正文和变量名称长度，内容不能为空或包含空字符", "Check title, body and variable labels. Empty content and null characters are not allowed.")
        case .invalidKeyword: return L10n.text("关键字格式应为 ;reply，最多 32 个字母、数字、短横线或下划线", "Use a keyword such as ;reply, with up to 32 letters, digits, hyphens or underscores.")
        case .invalidTemplate: return L10n.text("变量格式无效，请使用 {{name}}；变量名使用英文字母、数字或下划线", "Invalid template. Use {{name}} with ASCII letters, digits or underscores.")
        case .tooLarge: return L10n.text("超过限制：正文或结果 100KB、单个变量 10KB、最多 20 个变量", "Limit exceeded: 100KB template or output, 10KB per value, 20 variables.")
        case .requiredValue: return L10n.text("请填写所有必填变量", "Fill in all required variables.")
        case .conflict: return L10n.text("内容已变化，或名称/关键字已被使用；请检查后重试", "Content changed, or the name/keyword is already in use. Review and retry.")
        case .storage: return L10n.text("存储操作失败，内容仍保留，请重试", "Storage operation failed. Your content is preserved; please retry.")
        case .futureVersion: return L10n.text("数据库由更新版本创建，请升级应用", "This database requires a newer app version.")
        case .invalidGroup: return L10n.text("分组名需为 1–30 个字符且不能重复，请重新选择或命名", "Choose a valid group or a unique name of 1–30 characters.")
        }
    }
}
