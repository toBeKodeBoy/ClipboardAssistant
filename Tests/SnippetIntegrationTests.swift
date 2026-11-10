import AppKit
import Carbon
import XCTest
@testable import ClipboardAssistant

@MainActor
final class SnippetIntegrationTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "snippet-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(store: try HistoryStore(directory: url), settings: AppSettings(defaults: defaults))
        model.pasteService.pasteboard = NSPasteboard(name: .init(suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return model
    }

    func testHistoryClearAndRetentionDoNotDeleteSnippets() throws {
        let model = try makeModel()
        let snippet = try model.store.snippets.save(Snippet(title: "persistent", body: "template"))
        let captured = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [PasteboardItemData(values: [PasteboardUTI.plain: Data("history".utf8)])])))
        _ = try model.store.insertOrTouch(captured, sourceBundleID: nil, sourceName: "test")
        try model.store.clearAll()
        try model.store.applyRetention(model.settings.retention)
        XCTAssertEqual(try model.store.snippets.fetchAll(), [snippet])
        let reopened = try HistoryStore(directory: model.store.directory)
        XCTAssertEqual(try reopened.snippets.fetchAll(), [snippet])
    }

    func testVariablesCancelAndCopyDoNotCreateHistory() throws {
        let model = try makeModel()
        let library = model.snippetLibrary
        _ = try library.store.save(Snippet(title: "reply", body: "Hi {{name}}"))
        library.reload()
        let board = model.pasteService.pasteboard
        board.clearContents(); board.setString("before", forType: .string)
        library.beginUse(mode: .plainCopy)
        library.session?.values["name"] = "cancelled"
        library.close()
        XCTAssertNil(library.session)
        XCTAssertEqual(board.string(forType: .string), "before")
        library.beginUse(mode: .plainCopy)
        XCTAssertTrue(library.session?.values.isEmpty == true)
        library.session?.values["name"] = "Alice"
        library.submit()
        XCTAssertNil(library.session)
        XCTAssertEqual(board.string(forType: .string), "Hi Alice")
        XCTAssertTrue(try model.store.fetchAll().isEmpty)
        XCTAssertFalse(String(decoding: try XCTUnwrap(model.diagnosticsJSON()), as: UTF8.self).contains("Alice"))
    }

    func testMissingRequiredAndChangedTemplatePreserveFormWithoutWriting() throws {
        let model = try makeModel()
        let library = model.snippetLibrary
        let item = try library.store.save(Snippet(title: "reply", body: "Hi {{name}}"))
        library.reload(); library.beginUse(mode: .plainCopy)
        let count = model.pasteService.pasteboard.changeCount
        library.submit()
        XCTAssertNotNil(library.banner)
        XCTAssertEqual(model.pasteService.pasteboard.changeCount, count)
        library.session?.values["name"] = "preserve"
        var changed = item; changed.body = "new {{name}}"
        _ = try library.store.save(changed)
        library.submit()
        XCTAssertNotNil(library.session)
        XCTAssertEqual(library.session?.values["name"], "preserve")
        XCTAssertEqual(model.pasteService.pasteboard.changeCount, count)
    }

    func testSnippetPageCommandDeleteNeverClearsHistory() throws {
        let model = try makeModel()
        model.showingSnippets = true
        let panel = PanelController(model: model)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Delete)))
        _ = panel.handle(event)
        XCTAssertFalse(model.confirmClearAll)
        model.snippetLibrary.edit()
        _ = panel.handle(event)
        XCTAssertFalse(model.confirmClearAll)
        XCTAssertNotNil(model.snippetLibrary.draft)
        panel.closePanel()
        XCTAssertNil(model.snippetLibrary.draft)
    }

    func testTextPasteRejectsMissingTargetAndPreservesFailureSession() throws {
        let model = try makeModel()
        let service = model.pasteService
        let originalQuery = AccessibilityClient.queryTrusted
        defer { AccessibilityClient.queryTrusted = originalQuery }
        AccessibilityClient.queryTrusted = { _ in true }
        service.activateTextTarget = { _ in false }
        let library = model.snippetLibrary
        _ = try library.store.save(Snippet(title: "reply", body: "Hello"))
        library.reload()
        var prepared = false
        model.onPreparePaste = { prepared = true; library.close(preservingPaste: library.isBusy) }
        library.beginUse(mode: .automatic)
        XCTAssertTrue(prepared)
        XCTAssertFalse(library.isBusy)
        XCTAssertNotNil(library.session)
        XCTAssertEqual(library.banner, PasteOutcome.manualPasteMessage)
        XCTAssertEqual(service.pasteboard.string(forType: .string), "Hello")
    }

    func testHoverCopiesWithoutPreparingPasteOrChangingSelection() throws {
        let model = try makeModel()
        for text in ["first", "second"] {
            let captured = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [PasteboardItemData(values: [PasteboardUTI.plain: Data(text.utf8)])])))
            _ = try model.store.insertOrTouch(captured, sourceBundleID: nil, sourceName: "test")
        }
        model.reload()
        let first = try XCTUnwrap(model.items.first { $0.plainText == "first" })
        let second = try XCTUnwrap(model.items.first { $0.plainText == "second" })
        model.selectedID = first.id
        var prepared = false
        model.onPreparePaste = { prepared = true }
        model.copyHistoryOnHover(itemID: second.id)
        XCTAssertEqual(model.pasteService.pasteboard.string(forType: .string), "second")
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertFalse(prepared)
        model.copyHistoryOnHover(itemID: first.id)
        XCTAssertEqual(model.pasteService.pasteboard.string(forType: .string), "first")
        if let index = model.items.firstIndex(where: { $0.id == second.id }) {
            model.items[index].payloadOversize = true
        }
        model.copyHistoryOnHover(itemID: second.id)
        XCTAssertEqual(model.pasteService.pasteboard.string(forType: .string), "first")
    }

    func testHistorySnippetImportSupportsTextAndRichTextRepeatedly() throws {
        let model = try makeModel()
        let captured = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [PasteboardItemData(values: [PasteboardUTI.plain: Data("Hello {{name}}".utf8)])])))
        _ = try model.store.insertOrTouch(captured, sourceBundleID: nil, sourceName: "test")
        var item = try XCTUnwrap(model.store.fetchAll().first)
        let group = try model.store.snippets.saveGroup(name: "Work")
        for kind in [ItemKind.text, .rich] {
            item.kind = kind
            model.saveHistoryAsSnippet(item)
            XCTAssertTrue(model.showingSnippets)
            XCTAssertEqual(model.snippetLibrary.draft?.body, item.plainText)
            model.snippetLibrary.draft?.title = kind.rawValue
            model.snippetLibrary.draft?.groupID = group.id
            model.snippetLibrary.saveDraft()
            XCTAssertNil(model.snippetLibrary.draft)
            model.showingSnippets = false
        }
        let snippets = try model.store.snippets.fetchAll()
        XCTAssertEqual(snippets.count, 2)
        XCTAssertTrue(snippets.allSatisfy { $0.groupID == group.id })
        XCTAssertEqual(try model.store.count(), 1)
        for kind in [ItemKind.image, .file, .mixed] {
            item.kind = kind
            model.saveHistoryAsSnippet(item)
            XCTAssertNil(model.snippetLibrary.draft)
            XCTAssertFalse(model.showingSnippets)
        }
        item.kind = .rich
        item.payloadOversize = true
        model.saveHistoryAsSnippet(item)
        XCTAssertNil(model.snippetLibrary.draft)
        XCTAssertFalse(model.showingSnippets)
    }

    func testDraftSaveGroupingAndDiscardConfirmation() throws {
        let model = try makeModel()
        let library = model.snippetLibrary
        library.groupName = "Work"; library.saveGroup()
        library.edit(body: "Hello {{name}}")
        library.draft?.title = "Reply"
        library.reconcileVariables()
        library.draft?.variables[0].required = false
        library.saveDraft()
        XCTAssertNil(library.draft)
        XCTAssertEqual(library.selected?.groupID, library.groups.first?.id)
        library.edit(library.selected)
        library.draft?.title = "Changed"
        library.cancelDraft()
        XCTAssertTrue(library.confirmDiscard)
        library.discardDraft()
        XCTAssertEqual(library.selected?.title, "Reply")
    }
}
