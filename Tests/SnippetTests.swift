import XCTest
@testable import ClipboardAssistant

final class SnippetTests: XCTestCase {
    func testRepeatedVariablesEscapesAndNonRecursiveExpansion() throws {
        let parsed = try SnippetTemplate.parse(#"你好 {{name}} / {{name}} / \{{literal}} / \\"#)
        XCTAssertEqual(parsed.names, ["name"])
        XCTAssertEqual(try parsed.render(values: ["name": "{{other}}"]), #"你好 {{other}} / {{other}} / {{literal}} / \"#)
    }

    func testInvalidAndNestedTemplatesAreRejected() {
        for body in ["{{x", "{{}}", "{{a b}}", "{{{{a}}}}", "{{名字}}", "{{a}} }}", "{{a\n}}"] {
            XCTAssertThrowsError(try SnippetTemplate.parse(body), body)
        }
    }

    func testRequiredOptionalAndByteLimits() throws {
        let parsed = try SnippetTemplate.parse("{{required}}:{{optional}}")
        let definitions = [SnippetVariable(name: "required"), SnippetVariable(name: "optional", required: false)]
        XCTAssertThrowsError(try parsed.render(values: [:], variables: definitions))
        XCTAssertThrowsError(try parsed.render(values: ["required": "  "], variables: definitions))
        XCTAssertEqual(try parsed.render(values: ["required": "值"], variables: definitions), "值:")
        XCTAssertThrowsError(try parsed.render(values: ["required": String(repeating: "中", count: 3334)], variables: definitions))
        XCTAssertThrowsError(try SnippetTemplate.parse(String(repeating: "中", count: 33334)))
        let repeats = try SnippetTemplate.parse(String(repeating: "{{x}}", count: 11))
        XCTAssertThrowsError(try repeats.render(values: ["x": String(repeating: "a", count: 10000)]))
        XCTAssertThrowsError(try SnippetTemplate.parse((0...20).map { "{{v\($0)}}" }.joined()))
    }

    func testKeywordSearchCrossesGroupsButNormalSearchDoesNot() throws {
        let a = try Snippet(title: "回复", body: "Hello", groupID: "a", keyword: ";reply").validated()
        XCTAssertTrue(a.matches(query: ";REPLY", groupID: "b"))
        XCTAssertFalse(a.matches(query: ";rep", groupID: nil))
        XCTAssertFalse(a.matches(query: "hello", groupID: "b"))
        XCTAssertTrue(a.matches(query: "HELLO", groupID: "a"))
        XCTAssertThrowsError(try Snippet(title: " ", body: "x").validated())
        XCTAssertThrowsError(try Snippet(title: "x", body: "x", keyword: "reply").validated())
        XCTAssertThrowsError(try Snippet(title: "x", body: "x\0y").validated())
    }

    func testReconcileVariableSettingsByName() throws {
        var snippet = Snippet(title: "x", body: "{{b}} {{a}} {{b}}")
        snippet.variables = [SnippetVariable(name: "a", label: "姓名", required: false, multiline: true), SnippetVariable(name: "removed")]
        let validated = try snippet.validated()
        XCTAssertEqual(validated.variables.map(\.name), ["b", "a"])
        XCTAssertFalse(validated.variables[1].required)
        XCTAssertTrue(validated.variables[1].multiline)
    }
    func testLimitsAtBoundaryAndLocalizedErrors() throws {
        let value = String(repeating: "a", count: 10000)
        XCTAssertEqual(try SnippetTemplate.parse("{{x}}").render(values: ["x": value]), value)
        XCTAssertEqual(try SnippetTemplate.parse(String(repeating: "a", count: 100000)).render(values: [:]).utf8.count, 100000)
        XCTAssertEqual(try SnippetTemplate.parse(#"\{{"#).render(values: [:]), "{{")
        XCTAssertThrowsError(try Snippet(title: String(repeating: "a", count: 81), body: "text").validated())
        var snippet = Snippet(title: "x", body: "{{x}}")
        snippet.variables = [SnippetVariable(name: "x", label: String(repeating: "a", count: 81))]
        XCTAssertThrowsError(try snippet.validated())
        for error: SnippetError in [.invalidContent, .invalidKeyword, .invalidTemplate, .tooLarge, .requiredValue, .conflict, .storage, .futureVersion, .invalidGroup] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

}
