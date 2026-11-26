import SwiftUI

struct OperationLogView: View {
    let log: OperationLogStore
    let language: AppLanguage
    let revealRecovery: (RetainedRecovery) -> Bool
    @State private var selected: UUID?
    @State private var recoveryUnavailable = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地操作记录").font(.headline).accessibilityAddTraits(.isHeader)
            if log.entries.isEmpty {
                ContentUnavailableView("暂无操作记录", systemImage: "clock")
            } else {
                HSplitView {
                    List(selection: $selected) {
                        ForEach(log.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: entry.diskName).fontWeight(.medium).lineLimit(1)
                                HStack {
                                    Text(entry.kind == .scan ? "扫描" : entry.method == .permanentDelete ? "永久删除"
                                         : entry.automatic == true ? "自动清理" : "清理")
                                    Text(entry.date, format: .dateTime.month().day().hour().minute())
                                }
                                .font(.caption)
                            }
                            .tag(entry.id)
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 205)
                    if let entry = log.entries.first(where: { $0.id == selected }) ?? log.entries.first {
                        detail(entry).frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620, height: 405)
        .alert("找不到恢复文件夹", isPresented: $recoveryUnavailable) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请连接原磁盘，或检查文件夹是否已移动。")
        }
        .environment(\.locale, language.locale)
    }

    private func detail(_ entry: OperationLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                .foregroundStyle(.secondary)
            LabeledContent(entry.kind == .scan ? "发现的文件"
                           : entry.method == .permanentDelete ? "成功永久删除" : "成功移入废纸篓") {
                Text(entry.tally.count, format: .number)
            }
            LabeledContent("总大小") { Text(entry.tally.bytes, format: .byteCount(style: .file)) }
            if entry.kind == .cleanup {
                LabeledContent("失败") { Text(entry.failed, format: .number) }
                LabeledContent("跳过") { Text(entry.skipped, format: .number) }
                if let unprocessed = entry.unprocessed {
                    LabeledContent("停止时尚未处理") { Text(unprocessed, format: .number) }
                }
                if let recovery = entry.retainedRecovery {
                    LabeledContent("留在原盘恢复文件夹") { Text(recovery.tally.count, format: .number) }
                    Button("在 Finder 中显示恢复文件夹") {
                        recoveryUnavailable = !revealRecovery(recovery)
                    }
                }
                if let folder = entry.recoveryFolder {
                    LabeledContent("恢复文件夹") {
                        Text(verbatim: folder.path(percentEncoded: false))
                            .font(.caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(Text(verbatim: folder.path(percentEncoded: false)))
                    }
                }
            }
            if entry.issueCount > 0 {
                Text("显示 \(entry.issues.count) / \(entry.issueCount) 条问题").foregroundStyle(.secondary)
                List(entry.issues) { issue in IssueRow(issue: issue, language: language) }
            }
        }
        .padding(10)
    }
}
