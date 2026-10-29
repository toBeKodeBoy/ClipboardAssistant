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

enum AppIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private static let fallback: NSImage = {
        let image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    static func image(bundleID: String?) -> NSImage {
        let key = (bundleID ?? "") as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = load(bundleID: bundleID) ?? fallback
        cache.setObject(image, forKey: key)
        return image
    }

    private static func load(bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }
}

enum SecureInput {
    static func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }
}
