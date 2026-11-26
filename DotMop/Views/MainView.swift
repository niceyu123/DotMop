import SwiftUI

struct MainView: View {
    let coordinator: AppCoordinator

    var body: some View {
        @Bindable var model = coordinator.model
        VStack(spacing: 0) {
            header
            Divider()
            if let entry = model.operationLog.pendingRecovery, let recovery = entry.retainedRecovery {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("有文件留在原盘的恢复文件夹").fontWeight(.semibold)
                            Text(verbatim: entry.diskName).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    Spacer()
                    Button("在 Finder 中显示恢复文件夹") {
                        if !model.revealRecoveryFolder(recovery) {
                            model.errorMessage = "找不到恢复文件夹。请连接原磁盘，或检查文件夹是否已移动。"
                        }
                    }
                    Button("关闭提示") { model.operationLog.dismissRecoveryNotice(entry.id) }
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            HStack(spacing: 0) {
                DiskSelectionView(model: model)
                Divider()
                if let disk = model.selectedDisk {
                    VStack(spacing: 0) {
                        DiskDetailsView(disk: disk, model: model)
                        Divider()
                        ScanWorkspaceView(model: model, disk: disk, state: model.scans[disk.id])
                            .id(disk.id)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    empty
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(verbatim: coordinator.text(model.errorMessage ?? ""))
        }
        .sheet(item: $model.pendingCleanup, onDismiss: {
            model.cleanupConfirmationIsVisible = false
            model.processAutomaticCleanupQueue()
        }) { request in
            CleanupConfirmationView(request: request, confirm: { model.confirmCleanup(request) },
                                    cancel: { model.pendingCleanup = nil })
                .onAppear { model.cleanupConfirmationIsVisible = true }
        }
        .sheet(item: $model.cleanupReport, onDismiss: model.processAutomaticCleanupQueue) { report in
            CleanupReportView(report: report, language: coordinator.preferences.value.language,
                              revealRecovery: model.revealRecoveryFolder)
        }
        .environment(\.locale, coordinator.preferences.value.language.locale)
    }

    private var empty: some View {
        Group {
            if coordinator.model.disks.isEmpty {
                ContentUnavailableView(
                    "没有可扫描的外置磁盘",
                    systemImage: "externaldrive",
                    description: Text("连接移动硬盘、U 盘或 SD 卡后，磁盘会显示在这里。")
                )
            } else {
                ContentUnavailableView("选择磁盘", systemImage: "externaldrive", description: Text("请选择左侧的磁盘。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text("DotMop")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: coordinator.showSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
            .help("设置")
            .accessibilityIdentifier("settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
