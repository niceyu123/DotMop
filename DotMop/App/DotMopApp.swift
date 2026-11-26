import SwiftUI

@main
struct DotMopApp: App {
    @NSApplicationDelegateAdaptor(AppCoordinator.self) private var coordinator

    var body: some Scene {
        @Bindable var preferences = coordinator.preferences

        Settings {
            SettingsView(coordinator: coordinator)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button {
                    coordinator.showSettings()
                } label: {
                    Text(verbatim: coordinator.text("设置…"))
                }
                .keyboardShortcut(",")
            }
        }

        MenuBarExtra(isInserted: $preferences.value.showMenuBar) {
            MenuBarView(coordinator: coordinator)
        } label: {
            let pendingRecovery = coordinator.model.operationLog.pendingRecovery != nil
            let icon = pendingRecovery ? Image(systemName: "exclamationmark.triangle") : Image("DotMopMark")
            icon
                .renderingMode(.template)
                .accessibilityLabel(Text(verbatim: pendingRecovery
                                         ? "DotMop · " + coordinator.text("有文件留在原盘的恢复文件夹")
                                         : "DotMop"))
        }
    }
}
