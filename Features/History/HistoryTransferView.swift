import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class TransferCancellation {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

@MainActor
final class HistoryTransferModel: ObservableObject {
    enum Phase: Equatable { case export, validating, preview, committing, result }
    @Published var presented = false
    @Published var source = "history"
    @Published var phase: Phase = .export
    @Published var all = false
    @Published var plainText = false
    @Published var allowEviction = false
    @Published var progress = ""
    @Published var message: String?
    @Published private(set) var plan: HistoryImportPlan?
    private var archive: HistoryArchive?
    private var selection: Set<String>?
    private var cancellation = TransferCancellation()
    private var generation = UUID()
    let store: HistoryStore
    var policy: () -> RetentionPolicy
    var onChange: () -> Void = {}
    var selectImportFile: () -> URL? = {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    var selectExportFile: (Bool) -> URL? = { plain in
        let panel = NSSavePanel(); panel.allowedContentTypes = [plain ? .plainText : .json]
        panel.nameFieldStringValue = plain ? "clipboard-history.txt" : "clipboard-history.json"
        return panel.runModal() == .OK ? panel.url : nil
    }
    init(store: HistoryStore, policy: @escaping () -> RetentionPolicy) { self.store = store; self.policy = policy }
    var isBusy: Bool { phase == .validating || phase == .committing }
    var canCommit: Bool { phase == .preview && (plan?.candidates.isEmpty == false) && (plan!.existingEvicted == 0 || allowEviction) }
    var exportCount: Int { ((try? store.fetchAll()) ?? []).filter { all || selection == nil || selection!.contains($0.id) }.count }
    var exportEstimatedBytes: Int {
        let items = ((try? store.fetchAll()) ?? []).filter { all || selection == nil || selection!.contains($0.id) }
        return items.reduce(0) { total, item in
            total + ((item.payloadOversize || item.kind == .file) ? item.plainText.utf8.count : item.byteSize * 4 / 3 + item.plainText.utf8.count) + 1024
        }
    }
    func openExport(ids: Set<String>?, source: String) {
        reset(); selection = ids; all = ids == nil; self.source = source; phase = .export; presented = true
    }
    func reset() {
        cancellation.cancel(); cancellation = TransferCancellation(); generation = UUID()
        plan = nil; archive = nil; message = nil; progress = ""; allowEviction = false
    }
    func close() {
        guard phase != .committing else { return }
        reset(); presented = false
    }
    func prepare(_ archive: HistoryArchive) throws {
        plan = try store.previewImport(archive, policy: policy())
        self.archive = archive; allowEviction = false; phase = .preview; message = nil
    }
    func chooseImport(source: String) {
        guard let url = selectImportFile() else { return }
        load(url, source: source)
    }
    func load(_ url: URL, source: String) {
        reset(); self.source = source; phase = .validating; presented = true
        let cancellation = cancellation, generation = generation, store = store, policy = policy()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (HistoryArchive, HistoryImportPlan) in
                let archive = try ArchiveStream.read(url, cancelled: { cancellation.isCancelled })
                return (archive, try store.previewImport(archive, policy: policy, cancelled: { cancellation.isCancelled }))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation else { return }
                do { let (archive, plan) = try result.get(); self.archive = archive; self.plan = plan; self.allowEviction = false; self.phase = .preview }
                catch { self.fail(error) }
            }
        }
    }
    func refreshPreview() {
        guard let archive else { return }
        do { try prepare(archive) } catch { fail(error) }
    }
    func commit() {
        guard canCommit, let plan else { return }
        phase = .committing; message = nil
        let store = store, policy = policy(), allow = allowEviction
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.commitImport(plan, policy: policy, allowExistingEviction: allow) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                do {
                    let retained = try result.get()
                    self.phase = .result
                    self.message = L10n.text("新增候选 \(plan.candidates.count) 条，实际写入并保留 \(retained) 条，重复跳过 \(plan.fileDuplicates + plan.localDuplicates) 条，策略淘汰新增 \(plan.newEvicted) 条、原历史 \(plan.existingEvicted) 条。", "\(plan.candidates.count) eligible new, \(retained) written and retained, \(plan.fileDuplicates + plan.localDuplicates) duplicates skipped. Policy removed \(plan.newEvicted) new and \(plan.existingEvicted) existing items.")
                    self.onChange()
                } catch ArchiveError.stalePlan {
                    self.refreshPreview()
                    self.message = L10n.text("历史或保留设置已变化，请重新确认预览", "History or retention settings changed. Review and confirm again.")
                } catch { self.fail(error) }
            }
        }
    }
    func chooseExport() {
        guard exportCount > 0 else { return }
        guard let url = selectExportFile(plainText) else { return }
        export(to: url)
    }
    func export(to url: URL) {
        do {
            let snapshot = try store.archiveSnapshot(ids: all ? nil : selection)
            guard !snapshot.entries.isEmpty else { throw ArchiveError.invalidRecord }
            phase = .validating
            let flag = cancellation, generation = generation, plain = plainText
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try snapshot.write(to: url, plainText: plain, cancelled: { flag.isCancelled }) { current, total in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, generation == self.generation else { return }
                        self.progress = "\(current) / \(total)"
                    }
                } }
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.generation else { return }
                    do { try result.get(); self.phase = .result; self.message = L10n.text("导出完成", "Export complete") }
                    catch { self.fail(error) }
                }
            }
        } catch { fail(error) }
    }
    func fail(_ error: Error) {
        phase = .result
        switch error {
        case let failure as ArchiveRecordFailure:
            let category: String
            switch failure.category {
            case .invalid: category = L10n.text("条目格式无效", "Invalid record")
            case .resourceLimit: category = L10n.text("资源超过限制", "Resource limit exceeded")
            case .missingPayload: category = L10n.text("缺少负载", "Missing payload")
            }
            message = L10n.text("第 \(failure.index) 条：\(category)，整批未导入", "Record \(failure.index): \(category). Nothing was imported.")
        case is CancellationError: message = L10n.text("已取消", "Cancelled")
        case ArchiveError.limitExceeded: message = L10n.text("资源超过限制，请缩小范围", "Resource limit exceeded. Use a smaller range.")
        case ArchiveError.missingPayload: message = L10n.text("历史负载缺失，未能完成操作", "History payload is missing. Operation could not finish.")
        case ArchiveError.invalidFormat, ArchiveError.invalidRecord, is DecodingError:
            message = L10n.text("备份格式或条目无效，整批未导入", "Invalid archive format or record. Nothing was imported.")
        default: message = L10n.text("文件或数据库操作失败，请重试", "File or database operation failed. Please retry.")
        }
    }
}

struct HistoryTransferView: View {
    @ObservedObject var model: HistoryTransferModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("历史导入与导出", "History import and export")).font(.headline)
            if model.phase == .export {
                Toggle(L10n.text("全部历史", "All history"), isOn: $model.all)
                Picker(L10n.text("格式", "Format"), selection: $model.plainText) {
                    Text(L10n.text("JSON 完整备份", "JSON backup")).tag(false)
                    Text(L10n.text("TXT 文本（不可导入）", "TXT text (export only)")).tag(true)
                }
                Text(L10n.text("\(model.exportCount) 条，预计约 \(ByteCountFormatter.string(fromByteCount: Int64(model.exportEstimatedBytes), countStyle: .file))（实际以编码为准）", "\(model.exportCount) items, approximately \(ByteCountFormatter.string(fromByteCount: Int64(model.exportEstimatedBytes), countStyle: .file)) (encoding may vary)"))
                Text(L10n.text("导出包含明文历史和本地路径，请自行保管。文件仅保存引用。", "Exports contain readable history and local paths. Keep them safe. Referenced files are not copied."))
                Button(L10n.text("选择保存位置…", "Choose destination…"), action: model.chooseExport).disabled(model.exportCount == 0)
            }
            if model.phase == .preview, let plan = model.plan {
                Text(L10n.text("文件共 \(plan.total) 条；文件内重复 \(plan.fileDuplicates) 条，本地重复 \(plan.localDuplicates) 条。", "\(plan.total) records; \(plan.fileDuplicates) duplicates in file, \(plan.localDuplicates) local duplicates."))
                Text(L10n.text("有效新增 \(plan.candidates.count) 条，新增将淘汰 \(plan.newEvicted) 条，原历史将淘汰 \(plan.existingEvicted) 条，净变化 \(plan.netChange)。", "\(plan.candidates.count) new; policy removes \(plan.newEvicted) new and \(plan.existingEvicted) existing. Net change: \(plan.netChange)."))
                Text(L10n.text("主动导入不运行采集过滤；文件引用可能失效。仅预览条目按预览快照去重，不能恢复原文。", "Import does not run capture filters. File references may be unavailable. Preview-only items deduplicate by preview and cannot restore the original."))
                if plan.existingEvicted > 0 {
                    Toggle(L10n.text("确认按保留策略淘汰上述原历史", "Allow retention policy to remove the existing items shown above"), isOn: $model.allowEviction)
                }
                Button(L10n.text("确认导入", "Confirm import"), action: model.commit).disabled(!model.canCommit)
            }
            if model.isBusy {
                ProgressView()
                Text(model.phase == .committing ? L10n.text("正在完成导入，此时不可取消", "Completing import. Cancellation is unavailable.") : L10n.text("处理中，可取消", "Working. You may cancel."))
                Text(model.progress)
            }
            if let message = model.message { Text(message).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            Button(L10n.text("关闭", "Close"), action: model.close).disabled(model.phase == .committing)
        }
        .padding(20).frame(minWidth: 360, idealWidth: 400, minHeight: 280)
        .interactiveDismissDisabled(model.phase == .committing)
    }
}
