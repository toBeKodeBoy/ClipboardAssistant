import SwiftUI
import AppKit

struct ClipboardPanelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SnippetPanelContainer(model: model, library: model.snippetLibrary)
    }
}

private struct SnippetPanelContainer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: SnippetLibraryModel

    var body: some View {
        VStack(spacing: 8) {
            Picker(L10n.text("内容", "Content"), selection: $model.showingSnippets) {
                Text(L10n.text("历史", "History")).tag(false)
                Text(L10n.text("片段", "Snippets")).tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .disabled(model.snippetLibrary.hasModal || model.snippetLibrary.isBusy)
            if model.showingSnippets {
                SnippetPanelView(library: model.snippetLibrary)
            } else {
                HistoryPanelView()
            }
        }
        .onChange(of: model.showingSnippets) { _, showing in
            if showing { model.snippetLibrary.reload() }
            else { model.snippetLibrary.close() }
        }
    }
}

struct SnippetPanelView: View {
    @ObservedObject var library: SnippetLibraryModel

    var body: some View {
        VStack(spacing: 8) {
            if library.groupEditor {
                groupEditor
            } else if library.draft != nil {
                SnippetEditorView(library: library)
            } else if library.session != nil {
                SnippetFillView(library: library)
            } else {
                browser
            }
            if let banner = library.banner {
                Text(banner).font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .disabled(library.isBusy)
        .alert(L10n.text("删除片段？", "Delete snippet?"), isPresented: Binding(get: { library.pendingDelete != nil }, set: { if !$0 { library.pendingDelete = nil } })) {
            let captured = library.pendingDelete
            Button(L10n.text("取消", "Cancel"), role: .cancel) { library.pendingDelete = nil }
            Button(L10n.text("删除", "Delete"), role: .destructive) { library.deleteConfirmed(captured) }
        } message: { Text(L10n.text("删除后无法撤销。", "This cannot be undone.")) }
        .alert(L10n.text("删除分组？", "Delete group?"), isPresented: Binding(get: { library.pendingDeleteGroup != nil }, set: { if !$0 { library.pendingDeleteGroup = nil } })) {
            let captured = library.pendingDeleteGroup
            Button(L10n.text("取消", "Cancel"), role: .cancel) { library.pendingDeleteGroup = nil }
            Button(L10n.text("删除分组", "Delete group"), role: .destructive) { library.deleteGroupConfirmed(captured) }
        } message: { Text(L10n.text("片段将移到未分组，不会删除内容。", "Snippets will move to Ungrouped and keep their content.")) }
        .alert(L10n.text("放弃编辑？", "Discard changes?"), isPresented: $library.confirmDiscard) {
            Button(L10n.text("继续编辑", "Keep editing"), role: .cancel) { }
            Button(L10n.text("放弃", "Discard"), role: .destructive) { library.discardDraft() }
        }
        .onAppear { library.reload() }
        .onChange(of: library.query) { _, _ in library.selectedID = library.visibleItems.first?.id }
        .onChange(of: library.groupID) { _, _ in library.selectedID = library.visibleItems.first?.id }
    }

    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("分组名称", "Group name")).font(.headline)
            TextField(L10n.text("名称（1–30 个字符）", "Name (1–30 characters)"), text: $library.groupName)
            HStack {
                Button(L10n.text("取消", "Cancel")) { library.groupEditor = false; library.groupName = ""; library.editingGroup = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("保存", "Save")) { library.saveGroup() }.keyboardShortcut(.return, modifiers: .command)
            }
            Spacer()
        }.padding(16)
    }

    private var browser: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(L10n.text("搜索片段或输入 ;keyword", "Search snippets or enter ;keyword"), text: $library.query)
                Button(L10n.text("新建片段", "New snippet")) { library.edit() }
            }.padding(.horizontal, 12)
            HStack {
                Picker(L10n.text("分组", "Group"), selection: $library.groupID) {
                    Text(L10n.text("全部片段", "All snippets")).tag(nil as String?)
                    Text(L10n.text("未分组", "Ungrouped")).tag("" as String?)
                    ForEach(library.groups) { group in Text(group.name).tag(group.id as String?) }
                }
                Menu(L10n.text("管理分组", "Manage groups")) {
                    Button(L10n.text("新建分组", "New group")) { library.editingGroup = nil; library.groupName = ""; library.groupEditor = true }
                    if let group = library.groups.first(where: { $0.id == library.groupID }) {
                        Button(L10n.text("重命名分组", "Rename group")) {
                            library.editingGroup = group; library.groupName = group.name; library.groupEditor = true
                        }
                        Button(L10n.text("删除分组", "Delete group"), role: .destructive) { library.pendingDeleteGroup = group }
                    }
                }
            }.padding(.horizontal, 12)
            if library.query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(";") {
                Text(L10n.text("关键字跨分组精确匹配，回车确认使用", "Exact keyword match across groups. Press Return to use.")).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                if proxy.size.width >= 720 {
                    HStack(spacing: 0) { snippetList.frame(width: 260); Divider(); preview }
                } else {
                    VStack(spacing: 0) { snippetList; Divider(); preview.frame(height: max(140, proxy.size.height * 0.5)) }
                }
            }
            Text(L10n.text("回车 粘贴 · ⌘回车 只复制 · ⇧回车 纯文本", "Return Paste · ⌘Return Copy · ⇧Return Plain text"))
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }

    private var snippetList: some View {
        Group {
            if library.visibleItems.isEmpty {
                Text(library.query.isEmpty ? L10n.text("暂无片段，点击新建开始", "No snippets here. Create one to begin.") : L10n.text("未找到片段", "No matching snippets"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $library.selectedID) {
                    ForEach(library.visibleItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).lineLimit(1)
                            Text(item.keyword.isEmpty ? String(item.body.prefix(60)) : item.keyword).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(item.id)
                        .contextMenu {
                            Button(L10n.text("编辑", "Edit")) { library.edit(item) }
                            Button(L10n.text("删除", "Delete"), role: .destructive) { library.pendingDelete = item }
                        }
                    }
                }.listStyle(.plain)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = library.selected {
                Text(item.title).font(.headline)
                ScrollView { Text(item.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button(L10n.text("粘贴", "Paste")) { library.beginUse(mode: .automatic) }
                    Button(L10n.text("只复制", "Copy only")) { library.beginUse(mode: .plainCopy) }
                    Button(L10n.text("编辑", "Edit")) { library.edit(item) }
                }
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SnippetEditorView: View {
    @ObservedObject var library: SnippetLibraryModel

    private func field<T>(_ path: WritableKeyPath<Snippet, T>, fallback: T) -> Binding<T> {
        Binding(get: { library.draft?[keyPath: path] ?? fallback }, set: { library.draft?[keyPath: path] = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("编辑片段", "Edit snippet")).font(.headline)
                TextField(L10n.text("标题（最多 80 字符）", "Title (up to 80 characters)"), text: field(\.title, fallback: ""))
                Picker(L10n.text("分组", "Group"), selection: field(\.groupID, fallback: nil)) {
                    Text(L10n.text("未分组", "Ungrouped")).tag(nil as String?)
                    ForEach(library.groups) { Text($0.name).tag($0.id as String?) }
                }
                TextField(L10n.text("关键字（选填，例如 ;reply）", "Keyword (optional, e.g. ;reply)"), text: field(\.keyword, fallback: ""))
                Text(L10n.text("正文 · 使用 {{name}} 插入变量", "Body · Insert variables with {{name}}"))
                SnippetBodyEditor(text: field(\.body, fallback: ""))
                    .frame(height: 180).border(.quaternary)
                    .accessibilityLabel(L10n.text("片段正文", "Snippet body"))
                if let draft = library.draft {
                    ForEach(draft.variables.indices, id: \.self) { index in
                        variableSettings(index)
                    }
                }
                HStack {
                    Button(L10n.text("取消", "Cancel")) { library.cancelDraft() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L10n.text("保存片段", "Save snippet")) { library.saveDraft() }.keyboardShortcut(.return, modifiers: .command)
                }
            }.padding(16)
        }
        .onChange(of: library.draft?.body) { _, _ in library.reconcileVariables() }
        .onAppear { library.reconcileVariables() }
    }

    private func variableSettings(_ index: Int) -> some View {
        let variable = library.draft?.variables[safe: index] ?? SnippetVariable(name: "")
        return VStack(alignment: .leading, spacing: 6) {
            Text(variable.name).font(.caption.monospaced())
            TextField(L10n.text("变量显示名（选填）", "Variable label (optional)"), text: Binding(
                get: { library.draft?.variables[safe: index]?.label ?? "" },
                set: { if library.draft?.variables.indices.contains(index) == true { library.draft?.variables[index].label = $0 } }
            ))
            HStack {
                Toggle(L10n.text("必填", "Required"), isOn: variableBinding(index, \.required))
                Toggle(L10n.text("多行", "Multiline"), isOn: variableBinding(index, \.multiline))
            }
        }
    }

    private func variableBinding(_ index: Int, _ path: WritableKeyPath<SnippetVariable, Bool>) -> Binding<Bool> {
        Binding(get: { library.draft?.variables[safe: index]?[keyPath: path] ?? false }, set: {
            if library.draft?.variables.indices.contains(index) == true { library.draft?.variables[index][keyPath: path] = $0 }
        })
    }
}

/// Give the native text layout an explicit viewport and inset, including for CJK glyphs.
struct SnippetBodyEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(L10n.text("片段正文", "Snippet body"))
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView else { return }
        // Do not reset selection, scrolling or marked text during ordinary typing.
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}

private struct SnippetFillView: View {
    @ObservedObject var library: SnippetLibraryModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(library.session?.snippet.title ?? "").font(.headline)
                ForEach(library.session?.snippet.variables ?? []) { variable in
                    VStack(alignment: .leading) {
                        Text(variable.displayName + (variable.required ? L10n.text("（必填）", " (required)") : L10n.text("（选填）", " (optional)")))
                        if variable.multiline {
                            TextEditor(text: value(variable.name)).frame(minHeight: 70).border(.quaternary).accessibilityLabel(variable.displayName)
                        } else { TextField(variable.displayName, text: value(variable.name)) }
                    }
                }
                Text(L10n.text("展开预览", "Expanded preview")).font(.headline)
                Text(library.preview()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                HStack {
                    Button(L10n.text("取消", "Cancel")) { library.session = nil; library.banner = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(library.session?.mode.sendsKeystroke == false ? L10n.text("只复制", "Copy only") : L10n.text("粘贴", "Paste")) { library.submit() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
                Text(L10n.text("填写值仅本次有效；⌘回车执行，取消不会修改剪切板", "Values are used only for this session. ⌘Return submits; cancel keeps the clipboard unchanged.")).font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
    private func value(_ name: String) -> Binding<String> {
        Binding(get: { library.session?.values[name] ?? "" }, set: { library.session?.values[name] = $0 })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
