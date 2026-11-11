import XCTest
@testable import ClipboardAssistant

final class RulesTests: XCTestCase {
    func testTagValidationAndMapping() throws {
        let rule = try AppTagRule(bundleID: "com.apple.Safari", label: "  资料  ")
        XCTAssertEqual(rule.label, "资料")
        XCTAssertEqual(rule.tag(for: "com.apple.Safari"), "资料")
        XCTAssertNil(rule.tag(for: nil))
        XCTAssertNil(rule.tag(for: "other"))
        var disabled = rule; disabled.enabled = false
        XCTAssertNil(disabled.tag(for: rule.bundleID))
        for label in ["", " \n", "a\nb", String(repeating: "a", count: 31)] {
            XCTAssertThrowsError(try AppTagRule(bundleID: "app", label: label))
        }
        XCTAssertThrowsError(try AppTagRule(bundleID: "", label: "ok"))
    }
    func testIgnoreRuleValidation() throws {
        let rule = try TextIgnoreRule(name: " Test ", pattern: "验证码")
        XCTAssertEqual(rule.name, "Test")
        XCTAssertFalse(rule.matchesEmpty)
        XCTAssertTrue(try TextIgnoreRule(name: "all", pattern: ".*").matchesEmpty)
        for pattern in ["", "[", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try TextIgnoreRule(name: "test", pattern: pattern))
        }
        XCTAssertThrowsError(try TextIgnoreRule(name: "", pattern: "a"))
        XCTAssertThrowsError(try TextIgnoreRule(name: String(repeating: "a", count: 81), pattern: "a"))
    }
    func testRuleConfigurationRejectsDuplicatesAndTooManyRules() throws {
        let rule = try AppTagRule(bundleID: "app", label: "tag")
        XCTAssertThrowsError(try CaptureRuleSet(tags: [rule, rule], ignores: []))
        let ignore = try TextIgnoreRule(name: "test", pattern: "a")
        XCTAssertThrowsError(try CaptureRuleSet(tags: [], ignores: Array(repeating: ignore, count: 51)))
        XCTAssertEqual(try CaptureRuleSet(tags: [rule], ignores: []).tag(for: "app"), "tag")
    }
    func testPrivacyGateRejectsMatchedAndUnavailableEvaluation() {
        var decision = PrivacyDecision(isPaused: false, secureInputEnabled: false, recordDuringSecureInput: false,
            ignoreConcealed: true, hasConcealedMarker: false, sourceBundleID: nil, excludedBundleIDs: [], isSelfWrite: false)
        XCTAssertTrue(PrivacyGate.allowsCapture(decision))
        decision.matchedIgnoreRule = true
        XCTAssertFalse(PrivacyGate.allowsCapture(decision))
        decision.matchedIgnoreRule = false; decision.ruleEvaluationUnavailable = true
        XCTAssertFalse(PrivacyGate.allowsCapture(decision))
    }
}
