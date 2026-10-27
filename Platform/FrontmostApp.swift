import AppKit
import Carbon
import Foundation

enum FrontmostApp {
    static func current() -> (bundleID: String?, name: String) {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? L10n.text("未知应用", "Unknown App")
        return (app?.bundleIdentifier, name)
    }

    static func runningApplication(bundleID: String?) -> NSRunningApplication? {
        guard let bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
}

enum SecureInput {
    static func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }
}
