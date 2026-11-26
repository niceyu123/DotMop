import SwiftUI

extension View {
    func appleDoubleWarning(isPresented: Binding<Bool>, accept: @escaping () -> Void) -> some View {
        alert("AppleDouble 文件包含元数据", isPresented: isPresented) {
            Button("继续选择", action: accept)
            Button("取消", role: .cancel) {}
        } message: {
            Text("AppleDouble 可能包含扩展属性、Finder 信息和资源分叉。即使原文件仍在，清理这些文件也可能造成元数据丢失。")
        }
    }
}

struct CleanupConfirmationView: View {
    let request: CleanupRequest
    let confirm: () -> Void
    let cancel: () -> Void
    @State private var reviewPage = 0
    private let pageSize = 500
    private var isPermanent: Bool { request.method == .permanentDelete }

    var body: some View {
        let path = request.boundary.root.path(percentEncoded: false)
        VStack(alignment: .leading, spacing: 12) {
            Label(isPermanent ? "确认永久删除" : request.automatic ? "确认自动清理" : "确认移入废纸篓",
                  systemImage: isPermanent ? "exclamationmark.triangle" : "trash")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LabeledContent("磁盘") { Text(verbatim: request.diskName) }
            VStack(alignment: .leading, spacing: 4) {
                Text("扫描范围")
                Text(verbatim: path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(Text(verbatim: path))
            }
            Divider()
            tally("选中文件", value: request.selection)
            if isPermanent {
                Text("所选文件将从磁盘上永久删除，无法从废纸篓恢复。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.statistics.dsStore.count > 0 {
                tally(".DS_Store", value: request.statistics.dsStore).foregroundStyle(.secondary)
            }
            if request.statistics.appleDouble.count > 0 {
                tally("AppleDouble", value: request.statistics.appleDouble).foregroundStyle(.secondary)
            }
            if !request.hiddenSelection.isEmpty {
                Label(isPermanent ? "当前筛选隐藏了 \(request.hiddenSelection.count) 个已选文件，它们也会永久删除。"
                      : "当前筛选隐藏了 \(request.hiddenSelection.count) 个已选文件，它们也会移入废纸篓。",
                      systemImage: "line.3.horizontal.decrease.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("查看全部已选文件") {
                let pageCount = (request.files.count + pageSize - 1) / pageSize
                let files = Array(request.files.dropFirst(reviewPage * pageSize).prefix(pageSize))
                List(files) { file in
                    let filePath = file.url.path(percentEncoded: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: filePath)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(Text(verbatim: filePath))
                        HStack {
                            Text(verbatim: file.kind.label)
                            if request.hiddenSelection.contains(file.id) {
                                Text("当前筛选隐藏")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: filePath))
                    .accessibilityValue(request.hiddenSelection.contains(file.id) ? Text("当前筛选隐藏") : Text(verbatim: file.kind.label))
                }
                .frame(height: 178)
                .padding(.top, 5)
                if pageCount > 1 {
                    HStack {
                        Spacer()
                        Button("上一页") { reviewPage -= 1 }.disabled(reviewPage == 0)
                        Text("第 \(reviewPage + 1) / \(pageCount) 页").monospacedDigit()
                        Button("下一页") { reviewPage += 1 }.disabled(reviewPage + 1 >= pageCount)
                    }
                    .controlSize(.small)
                }
            }
            if request.statistics.appleDouble.count > 0 {
                Label("所选项目包含 AppleDouble 文件，清理后可能丢失原文件的元数据。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(isPermanent ? "永久删除" : "移入废纸篓", role: .destructive, action: confirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 490)
    }

    private func tally(_ label: LocalizedStringKey, value: FileTally) -> some View {
        LabeledContent(label) {
            HStack(spacing: 12) {
                Text("\(value.count) 个文件")
                Text(value.bytes, format: .byteCount(style: .file))
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        }
    }
}

struct CleanupReportView: View {
    let report: CleanupReport
    let language: AppLanguage
    let revealRecovery: (RetainedRecovery) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var recoveryUnavailable = false

    var body: some View {
        let isPermanent = report.method == .permanentDelete
        let tally = isPermanent ? report.result.deleted : report.result.moved
        VStack(alignment: .leading, spacing: 11) {
            Label("清理结果", systemImage: "trash")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: report.diskName).foregroundStyle(.secondary)
            LabeledContent(isPermanent ? "成功永久删除" : "成功移入废纸篓") { Text(tally.count, format: .number) }
            LabeledContent(isPermanent ? "已删除文件的总大小" : "已移动文件的总大小") {
                Text(tally.bytes, format: .byteCount(style: .file))
            }
            LabeledContent("失败") { Text(report.result.failed, format: .number) }
            LabeledContent("跳过") { Text(report.result.skipped, format: .number) }
            if report.result.unprocessed > 0 {
                LabeledContent("停止时尚未处理") { Text(report.result.unprocessed, format: .number) }
            }
            if let recovery = report.result.retainedRecovery {
                LabeledContent("留在原盘恢复文件夹") { Text(recovery.tally.count, format: .number) }
            }
            if let folder = report.result.recoveryFolder {
                Text("打开恢复文件夹中的 Restore.txt 可查看恢复方法。")
                    .foregroundStyle(.secondary)
                Button("在 Finder 中显示恢复文件夹") {
                    if let recovery = report.result.retainedRecovery {
                        recoveryUnavailable = !revealRecovery(recovery)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            }
            if !report.result.issues.isEmpty {
                Divider()
                List(report.result.issues) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(issue.outcome == .failed ? "失败" : "跳过")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        IssueRow(issue: issue.file, language: language)
                    }
                }
                .frame(minHeight: 130, idealHeight: 195, maxHeight: 230)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .alert("找不到恢复文件夹", isPresented: $recoveryUnavailable) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请连接原磁盘，或检查文件夹是否已移动。")
        }
        .environment(\.locale, language.locale)
    }
}
