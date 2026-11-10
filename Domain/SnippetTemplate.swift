import Foundation

/// A bounded, non-executable template language. Values are never parsed a second time.
struct SnippetTemplate {
    enum Token { case literal(String), variable(String) }
    let tokens: [Token]
    let names: [String]

    static func parse(_ body: String) throws -> SnippetTemplate {
        guard body.utf8.count <= 100_000 else { throw SnippetError.tooLarge }
        var tokens: [Token] = []
        var names: [String] = []
        var literal = ""
        var index = body.startIndex
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        while index < body.endIndex {
            let tail = body[index...]
            if tail.hasPrefix("\\\\") {
                literal.append("\\"); index = body.index(index, offsetBy: 2)
            } else if tail.hasPrefix("\\{{") {
                // Consume the escaped placeholder as a literal, including its closing braces.
                let start = body.index(index, offsetBy: 3)
                if let end = body[start...].range(of: "}}") {
                    literal += "{{" + body[start..<end.upperBound]
                    index = end.upperBound
                } else {
                    literal += "{{"; index = start
                }
            } else if tail.hasPrefix("{{") {
                flush()
                let start = body.index(index, offsetBy: 2)
                guard let end = body[start...].range(of: "}}") else { throw SnippetError.invalidTemplate }
                let name = String(body[start..<end.lowerBound])
                guard name.range(of: "^[A-Za-z][A-Za-z0-9_]{0,31}$", options: .regularExpression) != nil else {
                    throw SnippetError.invalidTemplate
                }
                tokens.append(.variable(name))
                if !names.contains(name) { names.append(name) }
                guard names.count <= 20 else { throw SnippetError.tooLarge }
                index = end.upperBound
            } else if tail.hasPrefix("}}") {
                throw SnippetError.invalidTemplate
            } else {
                literal.append(body[index]); index = body.index(after: index)
            }
        }
        flush()
        return SnippetTemplate(tokens: tokens, names: names)
    }

    func render(values: [String: String], variables: [SnippetVariable]? = nil) throws -> String {
        for name in names {
            let value = values[name] ?? ""
            guard value.utf8.count <= 10_000, !value.contains("\0") else { throw SnippetError.tooLarge }
            let required = variables?.first(where: { $0.name == name })?.required ?? true
            if required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SnippetError.requiredValue }
        }
        var output = ""
        var size = 0
        for token in tokens {
            let part: String
            switch token {
            case .literal(let text): part = text
            case .variable(let name): part = values[name] ?? ""
            }
            size += part.utf8.count
            guard size <= 100_000 else { throw SnippetError.tooLarge }
            output += part
        }
        return output
    }
}
