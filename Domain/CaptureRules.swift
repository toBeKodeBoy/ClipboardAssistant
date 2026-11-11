import Foundation

enum RuleError: Error { case invalidTag, invalidPattern, duplicateApp, tooManyRules }

struct AppTagRule: Codable, Equatable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let label: String
    var enabled = true
    init(bundleID: String, label: String) throws {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, bundleID.utf8.count <= 255, !value.isEmpty,
              value.count <= 30, !value.contains(where: \.isNewline) else { throw RuleError.invalidTag }
        self.bundleID = bundleID; self.label = value.precomposedStringWithCanonicalMapping
    }
    func tag(for source: String?) -> String? { enabled && source == bundleID ? label : nil }
}

struct TextIgnoreRule: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    let name: String
    let pattern: String
    var enabled = true
    init(name: String, pattern: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80, !pattern.isEmpty, pattern.utf8.count <= 4096,
              (try? NSRegularExpression(pattern: pattern)) != nil else { throw RuleError.invalidPattern }
        self.name = value; self.pattern = pattern
    }
    var matchesEmpty: Bool {
        (try? NSRegularExpression(pattern: pattern).firstMatch(in: "", range: NSRange(location: 0, length: 0))) != nil
    }
}

struct CaptureRuleSet: Codable, Equatable {
    var tags: [AppTagRule]
    var ignores: [TextIgnoreRule]
    init(tags: [AppTagRule] = [], ignores: [TextIgnoreRule] = []) throws {
        guard ignores.count <= 50, tags.count <= 500 else { throw RuleError.tooManyRules }
        guard Set(tags.map(\.bundleID)).count == tags.count else { throw RuleError.duplicateApp }
        for rule in tags { _ = try AppTagRule(bundleID: rule.bundleID, label: rule.label) }
        for rule in ignores { _ = try TextIgnoreRule(name: rule.name, pattern: rule.pattern) }
        self.tags = tags; self.ignores = ignores
    }
    func tag(for source: String?) -> String? { tags.first { $0.bundleID == source }?.tag(for: source) }
    func validated() throws -> CaptureRuleSet { try CaptureRuleSet(tags: tags, ignores: ignores) }
}
