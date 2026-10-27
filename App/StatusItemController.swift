import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let panel: PanelController
    private let item: NSStatusItem
    private var settingsWindow: NSWindow?

    init(model: AppModel, panel: PanelController) {
        self.model = model
        self.panel = panel
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = icon()
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        model.onHotkey = { [weak self] in
            self?.panel.toggle(placement: .center)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.rememberFrontApp()
        model.refreshAccessibility()
        model.reload()
        rebuild(menu)
        item.button?.image = icon()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = Array(model.items.prefix(10))
        if recent.isEmpty {
            let empty = NSMenuItem(title: L10n.text("暂无记录", "No history"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in recent {
                let menuItem = NSMenuItem(title: String(entry.title.prefix(80)), action: #selector(pasteRecent(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = entry.id
                menu.addItem(menuItem)
            }
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: L10n.text("打开主面板", "Open panel"), action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let pauseTitle = model.settings.isPaused ? L10n.text("恢复记录", "Resume") : L10n.text("暂停记录", "Pause")
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    private func icon() -> NSImage {
        let paused = model.settings.isPaused
        let trusted = model.accessibilityTrusted
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let symbol = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            symbol?.isTemplate = false
            symbol?.draw(in: rect.insetBy(dx: 1, dy: 2))
            if paused {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 3))
                slash.line(to: NSPoint(x: 15, y: 15))
                slash.lineWidth = 1.4
                NSColor.black.setStroke()
                slash.stroke()
            }
            if !trusted {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func pasteRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.paste(mode: .automatic, itemID: id)
    }

    @objc private func openPanel() {
        panel.show()
    }

    @objc private func togglePause() {
        model.togglePause()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model))
            let window = NSWindow(contentViewController: host)
            window.title = L10n.text("设置", "Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 720, height: 480))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.appearance = model.settings.appearance.nsAppearance
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
