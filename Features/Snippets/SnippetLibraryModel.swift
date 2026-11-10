import Foundation
import SwiftUI

struct SnippetUseSession {
    var snippet: Snippet
    var mode: PasteMode
    var values: [String: String] = [:]
}

/// One library session. Rendered variable values never enter persistence or diagnostics.
@MainActor
final class SnippetLibraryModel: ObservableObject {
    @Published private(set) var items: [Snippet] = []
    @Published private(set) var groups: [SnippetGroup] = []
    @Published var query = ""
    @Published var groupID: String?
    @Published var selectedID: String?
    @Published var draft: Snippet?
    @Published var originalDraft: Snippet?
    @Published var session: SnippetUseSession?
    @Published var banner: String?
    @Published var pendingDelete: Snippet?
    @Published var pendingDeleteGroup: SnippetGroup?
    @Published var groupEditor = false
    @Published var editingGroup: SnippetGroup?
    @Published var groupName = ""
    @Published var confirmDiscard = false
    @Published private(set) var isBusy = false
    let store: SnippetStore
    var automaticCopiesOnly: () -> Bool = { false }
    var performPaste: ((String, PasteMode, @escaping (PasteOutcome) -> Void) -> Void)?

    init(store: SnippetStore) { self.store = store }
    var visibleItems: [Snippet] { items.filter { $0.matches(query: query, groupID: groupID) } }
    var selected: Snippet? { visibleItems.first { $0.id == selectedID } ?? visibleItems.first }
    var hasModal: Bool { draft != nil || session != nil || groupEditor || pendingDelete != nil || pendingDeleteGroup != nil || confirmDiscard }

    func reload() {
        do {
            // Publish only after both reads succeed. Never turn a storage failure into an empty list.
            let rows = try store.fetchAll()
            let folders = try store.fetchGroups()
            items = rows; groups = folders
            if !visibleItems.contains(where: { $0.id == selectedID }) { selectedID = visibleItems.first?.id }
        } catch { banner = SnippetError.storage.localizedDescription }
    }

    func edit(_ item: Snippet? = nil, body: String = "") {
        guard !isBusy else { return }
        let value = item ?? Snippet(title: "", body: body, groupID: groupID?.isEmpty == false ? groupID : nil)
        originalDraft = value; draft = value; banner = nil
    }

    func reconcileVariables() {
        guard var draft, let parsed = try? SnippetTemplate.parse(draft.body) else { return }
        draft.variables = parsed.names.map { name in draft.variables.first { $0.name == name } ?? SnippetVariable(name: name) }
        self.draft = draft
    }

    func saveDraft() {
        guard let draft else { return }
        do {
            let value = try store.save(draft)
            self.draft = nil; originalDraft = nil
            query = ""; groupID = nil; selectedID = value.id; banner = nil; reload()
        } catch { show(error) }
    }

    func cancelDraft() {
        if draft != originalDraft { confirmDiscard = true }
        else { discardDraft() }
    }

    func discardDraft() { draft = nil; originalDraft = nil; confirmDiscard = false; banner = nil }

    func saveGroup() {
        do {
            let group = try store.saveGroup(id: editingGroup?.id, name: groupName)
            groupID = group.id; groupEditor = false; groupName = ""; editingGroup = nil; banner = nil; reload()
        } catch { show(error) }
    }

    func deleteConfirmed(_ captured: Snippet? = nil) {
        guard let value = captured ?? pendingDelete else { return }
        do { try store.delete(id: value.id); pendingDelete = nil; banner = nil; reload() }
        catch { pendingDelete = nil; show(error) }
    }

    func deleteGroupConfirmed(_ captured: SnippetGroup? = nil) {
        guard let group = captured ?? pendingDeleteGroup else { return }
        do {
            try store.deleteGroup(id: group.id)
            pendingDeleteGroup = nil; groupID = ""; banner = nil; reload()
        } catch { pendingDeleteGroup = nil; show(error) }
    }

    func beginUse(mode: PasteMode) {
        guard !isBusy, let selected else { return }
        session = SnippetUseSession(snippet: selected, mode: mode == .automatic && automaticCopiesOnly() ? .plainCopy : mode)
        banner = nil
        if selected.variables.isEmpty { submit() }
    }

    func preview() -> String {
        guard let session, let parsed = try? SnippetTemplate.parse(session.snippet.body) else { return "" }
        let optional = session.snippet.variables.map { field -> SnippetVariable in var field = field; field.required = false; return field }
        return (try? parsed.render(values: session.values, variables: optional)) ?? L10n.text("内容超出限制", "Content exceeds limits")
    }

    func submit() {
        guard !isBusy, let session, let performPaste else { return }
        do {
            let latest = try store.fetchAll().first { $0.id == session.snippet.id }
            guard latest == session.snippet else { throw SnippetError.conflict }
            let parsed = try SnippetTemplate.parse(session.snippet.body)
            let text = try parsed.render(values: session.values, variables: session.snippet.variables)
            isBusy = true
            performPaste(text, session.mode) { [weak self] outcome in
                guard let self else { return }
                self.isBusy = false
                self.banner = outcome.message
                if outcome.message == nil { self.session = nil }
            }
        } catch { show(error) }
    }

    /// Closing for an in-flight keystroke preserves only that session for failure recovery.
    func close(preservingPaste: Bool = false) {
        if preservingPaste { return }
        session = nil; draft = nil; originalDraft = nil; groupEditor = false
        groupName = ""; editingGroup = nil; pendingDelete = nil; pendingDeleteGroup = nil; confirmDiscard = false
    }

    func moveSelection(down: Bool) {
        let rows = visibleItems
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = rows[down ? min(index + 1, rows.count - 1) : max(index - 1, 0)].id
    }

    private func show(_ error: Error) { banner = (error as? SnippetError ?? .storage).localizedDescription }
}
