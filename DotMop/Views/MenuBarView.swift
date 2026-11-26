import AppKit
import SwiftUI

struct MenuBarView: View {
    let coordinator: AppCoordinator

    var body: some View {
        let model = coordinator.model
        Button {
            coordinator.showMainWindow()
        } label: {
            Text(verbatim: coordinator.text("打开 DotMop"))
        }
        Divider()
        Text(verbatim: formatted("已连接 %lld 块磁盘", count: model.disks.count))
        if model.scans.values.contains(where: { $0.phase.isActive }) {
            Text(verbatim: coordinator.text("正在扫描…"))
        }
        if let latest = model.operationLog.entries.first(where: { $0.kind == .scan }) {
            Text(verbatim: "\(latest.diskName) · \(formatted("最近扫描发现 %lld 个文件", count: latest.tally.count))")
        } else {
            Text(verbatim: coordinator.text("暂无扫描结果"))
        }
        if let entry = model.operationLog.pendingRecovery, let recovery = entry.retainedRecovery {
            Text(verbatim: "\(entry.diskName) · \(coordinator.text("有文件留在原盘的恢复文件夹"))")
            Button {
                if !model.revealRecoveryFolder(recovery) {
                    coordinator.showMainWindow()
                    model.errorMessage = "找不到恢复文件夹。请连接原磁盘，或检查文件夹是否已移动。"
                }
            } label: {
                Text(verbatim: coordinator.text("在 Finder 中显示恢复文件夹"))
            }
        }
        Button {
            model.refreshDisks(scan: .manual)
        } label: {
            Text(verbatim: coordinator.text("重新扫描"))
        }
        Divider()
        Button {
            coordinator.showSettings()
        } label: {
            Text(verbatim: coordinator.text("设置…"))
        }
        Button {
            NSApp.terminate(nil)
        } label: {
            Text(verbatim: coordinator.text("退出 DotMop"))
        }
    }

    private func formatted(_ key: String, count: Int) -> String {
        String(format: coordinator.text(key), locale: coordinator.preferences.value.language.locale, Int64(count))
    }
}
