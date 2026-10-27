import AppKit
import SwiftUI

struct HistoryPanelView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmPinnedDelete = false

    var body: some View {
        VStack(spacing: 0) {
            searchField
            filters
            if model.items.isEmpty {
                emptyState
            } else {
                split
            }
            if let banner = model.banner {
                Text(banner)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.15))
            }
            footer
        }
        .frame(minWidth: 420, minHeight: 360)
        .alert(L10n.text("删除置顶条目？", "Delete pinned item?"), isPresented: $confirmPinnedDelete) {
            Button(L10n.text("删除", "Delete"), role: .destructive) { model.deletePinnedConfirmed() }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("这条内容已置顶。", "This item is pinned."))
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
            TextField(L10n.text("搜索文本、来源或文件名", "Search text, source, or file name"), text: $model.query)
                .textFieldStyle(.plain)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var filters: some View {
        HStack(spacing: 6) {
            ForEach(ItemFilter.allCases) { filter in
                Button(filter.title) { model.filter = filter }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(model.filter == filter ? Color.accentColor.opacity(0.16) : Color.clear)
                    .foregroundStyle(model.filter == filter ? Color.accentColor : Color.secondary)
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var split: some View {
        HStack(spacing: 0) {
            List(selection: $model.selectedID) {
                ForEach(model.groupedVisible(), id: \.0) { section, rows in
                    Section(section.title) {
                        ForEach(rows) { item in
                            row(item)
                                .tag(item.id)
                                .contextMenu { contextMenu(item) }
                                .onTapGesture(count: 2) { model.paste(mode: .automatic, itemID: item.id) }
                        }
                    }
                }
            }
            .frame(minWidth: 280)
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).lineLimit(1)
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var preview: some View {
        if let item = model.items.first(where: { $0.id == model.selectedID }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.sourceName).font(.headline)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(item.pinned ? L10n.text("取消置顶", "Unpin") : L10n.text("置顶", "Pin")) {
                        model.togglePin(id: item.id)
                    }
                }
                if item.payloadOversize {
                    Text(L10n.text("内容过大未保存", "Content was too large to save"))
                        .foregroundStyle(.secondary)
                } else if item.kind == .image, let url = model.thumbnailURL(for: item.id), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                } else {
                    ScrollView {
                        Text(item.plainText.isEmpty ? item.title : item.plainText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
            }
            .padding(16)
        } else {
            Text(L10n.text("没有可预览的内容", "Nothing to preview"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L10n.text("还没有复制记录", "No clipboard history yet"))
                .font(.title3)
            Text(L10n.text("在任意应用中复制文本、图片或文件，会自动出现在这里。", "Copy text, images, or files in any app and they will show up here."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(model.settings.hotkeyDisplay + "  " + L10n.text("打开主面板", "Open panel"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.accessibilityTrusted {
                Text(L10n.text("自动粘贴需要辅助功能权限。未授权时仍会记录历史。", "Automatic paste needs Accessibility. History is recorded without it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L10n.text("打开系统设置", "Open System Settings")) {
                    AccessibilityClient.openSettings()
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Text(L10n.text("回车 粘贴", "Return Paste"))
                Text(L10n.text("⌘回车 只复制", "⌘Return Copy"))
                Text(L10n.text("⇧回车 纯文本", "⇧Return Plain"))
                Text(L10n.text("删除 当前条", "Delete Current"))
                Spacer()
            }
            Text(HistoryCounts.tally(model.items).panelSummary(maxCount: model.settings.maxCount))
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func contextMenu(_ item: ClipboardItem) -> some View {
        Button(L10n.text("复制", "Copy")) { model.paste(mode: .copyOnly, itemID: item.id) }
        Button(L10n.text("纯文本复制", "Copy as Plain Text")) { model.paste(mode: .plainCopy, itemID: item.id) }
        Button(item.pinned ? L10n.text("取消置顶", "Unpin") : L10n.text("置顶", "Pin")) { model.togglePin(id: item.id) }
        if item.kind == .file || item.kind == .mixed {
            Button(L10n.text("在访达中显示", "Show in Finder")) { model.revealInFinder(id: item.id) }
        }
        Button(L10n.text("删除", "Delete"), role: .destructive) {
            model.selectedID = item.id
            if item.pinned {
                confirmPinnedDelete = true
            } else {
                model.deleteSelected()
            }
        }
    }
}
