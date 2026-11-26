import SwiftUI

struct FileListView: View {
    let files: [CleanableFile]
    let state: DiskScanState
    let canSelect: Bool
    @Binding var highlighted: UUID?
    let changeSelection: (Bool, [CleanableFile]) -> Void
    let reveal: (CleanableFile) -> Void

    var body: some View {
        Table(files, selection: $highlighted) {
            TableColumn("选中") { file in
                Toggle(isOn: Binding(get: { state.selected.contains(file.id) },
                                     set: { changeSelection($0, [file]) })) {
                    Text(verbatim: file.name)
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canSelect || !state.canSelect(file))
                .accessibilityLabel(Text(verbatim: file.name))
            }
            .width(46)

            TableColumn("名称与路径") { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file.name).lineLimit(1)
                    Text(verbatim: file.url.path(percentEncoded: false))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(Text(verbatim: file.url.path(percentEncoded: false)))
                .accessibilityElement(children: .combine)
            }
            .width(min: 140, ideal: 245)

            TableColumn("类型") { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file.kind.label)
                        .help(originalStatus(file))
                    if let issue = state.cleanupIssues[file.id] {
                        cleanupStatus(issue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .width(min: 75, ideal: 84, max: 110)

            TableColumn("大小") { file in
                Text(file.bytes, format: .byteCount(style: .file))
                    .monospacedDigit()
            }
            .width(min: 54, ideal: 64, max: 86)
        }
        .contextMenu(forSelectionType: UUID.self) { selected in
            if let file = file(in: selected) {
                Button("在 Finder 中显示") { reveal(file) }
            }
        } primaryAction: { selected in
            if let file = file(in: selected) { reveal(file) }
        }
        .accessibilityLabel(Text("扫描结果"))
    }

    private func cleanupStatus(_ issue: CleanupIssue) -> Text {
        if issue.disposition == .rescan { return Text("需重新扫描") }
        return Text(issue.outcome == .failed ? "失败" : "跳过")
    }

    private func file(in selected: Set<UUID>) -> CleanableFile? {
        guard let id = selected.first else { return nil }
        return files.first { $0.id == id }
    }

    private func originalStatus(_ file: CleanableFile) -> Text {
        guard file.kind == .appleDouble else { return Text(verbatim: ".DS_Store") }
        switch file.originalExists {
        case true?: return Text("找到对应原文件")
        case false?: return Text("未找到对应原文件")
        case nil: return Text("无法确认原文件是否存在")
        }
    }
}
