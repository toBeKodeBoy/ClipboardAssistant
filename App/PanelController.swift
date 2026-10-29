import AppKit
import Carbon
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: NSPanel
    private var keyMonitor: Any?
    private var outsideMonitor: Any?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: model.settings.panelWidth, height: model.settings.panelHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = L10n.text("剪切板助手", "Clipboard Assistant")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 420, height: 360)
        panel.contentViewController = NSHostingController(rootView: HistoryPanelView().environmentObject(model))
        panel.appearance = model.settings.appearance.nsAppearance
        model.onPreparePaste = { [weak self] in
            self?.closePanel()
        }
        model.onPasteFeedback = { [weak self] in
            self?.showFeedback()
        }
    }

    func toggle(placement: PanelPlacement? = nil) {
        if panel.isVisible {
            closePanel()
        } else {
            show(placement: placement)
        }
    }

    func show(rememberingFrontApp: Bool = true, clearingBanner: Bool = true, placement: PanelPlacement? = nil) {
        if rememberingFrontApp {
            model.rememberFrontApp()
        }
        model.refreshAccessibility()
        if clearingBanner {
            model.banner = nil
        }
        panel.appearance = model.settings.appearance.nsAppearance
        var frame = panel.frame
        frame.size = NSSize(width: model.settings.panelWidth, height: model.settings.panelHeight)
        frame.origin = origin(for: frame.size, placement: placement)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        installOutsideMonitor()
    }

    func showFeedback() {
        guard !panel.isVisible else { return }
        show(rememberingFrontApp: false, clearingBanner: false)
    }

    func closePanel() {
        model.confirmClearAll = false
        model.settings.panelWidth = panel.frame.width
        model.settings.panelHeight = panel.frame.height
        panel.orderOut(nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        closePanel()
    }

    private func origin(for size: NSSize, placement: PanelPlacement? = nil) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let resolved = placement ?? model.settings.panelPlacement
        var origin: NSPoint
        if resolved == .center {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        } else {
            origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    private func installOutsideMonitor() {
        if outsideMonitor != nil { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePanel()
            }
        }
    }

    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private var isSearchEditing: Bool {
        (panel.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    private func handle(_ event: NSEvent) -> Bool {
        if model.confirmClearAll {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Escape) {
            closePanel()
            return true
        }
        let commandOnly = flags.intersection([.command, .shift, .option, .control]) == .command
        if event.keyCode == UInt16(kVK_Delete) && commandOnly {
            if !model.items.isEmpty {
                model.confirmClearAll = true
            }
            return true
        }
        if isSearchEditing && passesToSearchField(event, flags: flags) {
            return false
        }
        if event.keyCode == UInt16(kVK_Return) {
            if flags.contains(.command) {
                model.paste(mode: .copyOnly)
            } else if flags.contains(.shift) {
                model.paste(mode: .plainText)
            } else {
                model.paste(mode: .automatic)
            }
            return true
        }
        if event.keyCode == UInt16(kVK_Delete) && !flags.contains(.command) {
            if model.items.first(where: { $0.id == model.selectedID })?.pinned == true {
                model.banner = L10n.text("置顶条目需要确认后再删除", "Pinned items need confirmation")
            } else {
                model.deleteSelected()
            }
            return true
        }
        if flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "z" {
            model.undoDelete()
            return true
        }
        if flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "p" {
            model.togglePin()
            return true
        }
        if flags.contains(.command), let character = event.charactersIgnoringModifiers, let number = Int(character), (1...9).contains(number) {
            let visible = model.visibleItems()
            if number <= visible.count {
                model.paste(mode: .automatic, itemID: visible[number - 1].id)
            }
            return true
        }
        if event.keyCode == UInt16(kVK_DownArrow) || event.keyCode == UInt16(kVK_UpArrow) {
            moveSelection(down: event.keyCode == UInt16(kVK_DownArrow))
            return true
        }
        return false
    }

    private func passesToSearchField(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.command) {
            let character = event.charactersIgnoringModifiers?.lowercased()
            return character == "z" || character == "a" || character == "c" || character == "v" || character == "x"
        }
        if flags.contains(.option) || flags.contains(.control) {
            return false
        }
        let editing: Set<UInt16> = [
            UInt16(kVK_Delete),
            UInt16(kVK_ForwardDelete),
            UInt16(kVK_LeftArrow),
            UInt16(kVK_RightArrow),
            UInt16(kVK_Home),
            UInt16(kVK_End)
        ]
        return editing.contains(event.keyCode)
    }

    private func moveSelection(down: Bool) {
        let visible = model.visibleItems()
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == model.selectedID } ?? 0
        let next = down ? min(visible.count - 1, index + 1) : max(0, index - 1)
        model.selectedID = visible[next].id
    }
}
