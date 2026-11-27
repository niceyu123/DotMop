import SwiftUI

struct DiskSelectionView: View {
    @Bindable var model: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("外置磁盘")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)

            if model.disks.isEmpty {
                if model.isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("读取磁盘中…")
                    }
                    .padding(.horizontal, 13)
                }
                Spacer()
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.disks) { entry in
                        diskRow(entry).tag(entry.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(Text("外置磁盘"))
            }
        }
        .frame(width: 172)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func diskRow(_ disk: DiskInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label {
                    Text(verbatim: disk.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .help(Text(verbatim: disk.name))
                } icon: {
                    Image(systemName: "externaldrive")
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                Text(verbatim: disk.format).font(.caption2).lineLimit(1).fixedSize()
                if model.ejectingDiskID == disk.id {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 20, height: 18)
                        .accessibilityLabel(Text("正在推出磁盘…"))
                } else {
                    Button {
                        Task { await model.ejectDisk(disk.id) }
                    } label: {
                        Label("推出", systemImage: "eject")
                            .labelStyle(.iconOnly)
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("eject-disk")
                    .accessibilityLabel(Text("推出磁盘") + Text(verbatim: " " + disk.name))
                    .help("推出磁盘")
                    .disabled(!model.canEjectDisk(disk.id))
                }
            }
            if let available = disk.availableBytes, available >= 0 {
                capacityRow("可用空间", bytes: available, emphasis: true)
            }
            if let total = disk.totalBytes, total > 0 {
                capacityRow("总容量", bytes: total)
                if let available = disk.availableBytes, (0...total).contains(available) {
                    let used = Double(total - available) / Double(total)
                    HStack(spacing: 6) {
                        ProgressView(value: used)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .tint(.primary)
                            .accessibilityHidden(true)
                        Text(used, format: .percent.precision(.fractionLength(0)))
                            .font(.caption2.monospacedDigit())
                            .fixedSize()
                            .accessibilityLabel(Text("空间使用率"))
                            .accessibilityValue(Text(used, format: .percent.precision(.fractionLength(0))))
                    }
                    .help("空间使用率")
                }
            }
        }
        .font(.caption)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private func capacityRow(_ title: LocalizedStringKey, bytes: Int64, emphasis: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer(minLength: 4)
            Text(bytes, format: .byteCount(style: .file))
                .monospacedDigit()
                .fontWeight(emphasis ? .semibold : .regular)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct DiskDetailsView: View {
    let disk: DiskInfo
    let model: MainViewModel

    private var folder: URL? { model.folderScopes[disk.id]?.root }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(verbatim: disk.name)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: disk.format).lineLimit(1)
                Text(disk.isReadOnly ? "只读" : "可写")
                Spacer(minLength: 8)
                if let free = disk.availableBytes {
                    Text("可用空间").fixedSize()
                    Text(free, format: .byteCount(style: .file)).fixedSize()
                }
            }
            HStack(spacing: 8) {
                Text("扫描范围").fixedSize()
                Menu {
                    Button("选择文件夹…") { model.chooseFolder(for: disk) }
                    if folder != nil {
                        Button("扫描整块磁盘") { model.scanWholeDisk(disk.id) }
                    }
                } label: {
                    if let folder {
                        Text(verbatim: folder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("整块磁盘")
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .accessibilityIdentifier("scan-scope")
                .disabled(model.isChoosingFolder || model.cleaningDiskID == disk.id || model.ejectingDiskID == disk.id
                          || model.needsVolumeAuthorization(disk))
                Spacer(minLength: 4)
                let mountPath = disk.volume.url.path(percentEncoded: false)
                Text(verbatim: mountPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(Text(verbatim: mountPath))
            }
            .accessibilityElement(children: .contain)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
