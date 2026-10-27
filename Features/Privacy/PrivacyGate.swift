import Foundation

struct PrivacyDecision: Equatable {
    var isPaused: Bool
    var secureInputEnabled: Bool
    var recordDuringSecureInput: Bool
    var ignoreConcealed: Bool
    var hasConcealedMarker: Bool
    var hasTransientMarker: Bool = false
    var sourceBundleID: String?
    var excludedBundleIDs: Set<String>
    var isSelfWrite: Bool
}

enum PrivacyGate {
    static func allowsCapture(_ decision: PrivacyDecision) -> Bool {
        if decision.isPaused { return false }
        if decision.isSelfWrite { return false }
        if decision.hasTransientMarker { return false }
        if decision.secureInputEnabled && !decision.recordDuringSecureInput { return false }
        if decision.ignoreConcealed && decision.hasConcealedMarker { return false }
        if let bundleID = decision.sourceBundleID, decision.excludedBundleIDs.contains(bundleID) {
            return false
        }
        return true
    }
}

enum DefaultExclusions {
    static let apps: [(bundleID: String, name: String)] = [
        ("com.apple.keychainaccess", "钥匙串访问"),
        ("com.apple.Passwords", "密码"),
        ("com.1password.1password", "1Password"),
        ("com.agilebits.onepassword7", "1Password 7"),
        ("com.bitwarden.desktop", "Bitwarden")
    ]
}
