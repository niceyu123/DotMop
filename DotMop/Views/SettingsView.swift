import SwiftUI

struct SettingsView: View {
    private enum Pane: CaseIterable {
        case general, scanning, cleanup, activity

        var title: LocalizedStringKey {
            switch self {
            case .general: "通用"
            case .scanning: "扫描"
            case .cleanup: "清理"
            case .activity: "操作记录"
            }
        }
    }

    let coordinator: AppCoordinator
    @State private var pane: Pane = .general
    @State private var showingAppleDoubleWarning = false
    @State private var showingLog = false
    @State private var showingPrivacyPolicy = false
    @State private var confirmingClearLog = false

    var body: some View {
        let preferences = coordinator.preferences
        VStack(spacing: 0) {
            Picker("设置类别", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { section in Text(section.title).tag(section) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()
            Form {
                switch pane {
                case .general: general
                case .scanning: scanning
                case .cleanup: cleanup
                case .activity: activity
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 555, height: 392)
        .environment(\.locale, preferences.value.language.locale)
        .onChange(of: preferences.value.appearance) { coordinator.applyAppearance() }
        .onChange(of: preferences.value.language) { coordinator.applyLanguage() }
        .onChange(of: preferences.value.cleanup) { coordinator.model.processAutomaticCleanupQueue() }
        .onAppear { coordinator.loginItems.refresh() }
        .appleDoubleWarning(isPresented: $showingAppleDoubleWarning) {
            preferences.value.acknowledgedAppleDouble = true
            preferences.value.selectAppleDouble = true
        }
        .alert("清除本地操作记录？", isPresented: $confirmingClearLog) {
            Button("取消", role: .cancel) {}
            Button("清除记录", role: .destructive) { coordinator.model.operationLog.clear() }
        }
        .sheet(isPresented: $showingPrivacyPolicy) {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView {
                    if let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
                       let policy = try? String(contentsOf: url, encoding: .utf8) {
                        Text(verbatim: policy)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Link("GitHub Issues", destination: URL(string: "https://github.com/niceyu123/DotMop/issues")!)
                    Spacer()
                    Button("关闭") { showingPrivacyPolicy = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 515, height: 360)
        }
        .sheet(isPresented: $showingLog) {
            OperationLogView(log: coordinator.model.operationLog, language: preferences.value.language,
                             revealRecovery: coordinator.model.revealRecoveryFolder)
        }
    }

    private var general: some View {
        @Bindable var preferences = coordinator.preferences
        let login = coordinator.loginItems
        return Group {
            Section {
                Toggle("登录时启动", isOn: Binding(
                    get: { login.isEnabled },
                    set: { enabled in Task { await login.setEnabled(enabled) } }
                ))
                .disabled(login.isUpdating || login.state == .requiresApproval)
                LabeledContent("系统状态") { Text(login.state.label).foregroundStyle(.secondary) }
                if login.state == .requiresApproval {
                    HStack {
                        Button("打开系统登录项设置") { login.openSystemSettings() }
                        Spacer()
                        Button("取消登录项") { Task { await login.setEnabled(false) } }
                            .disabled(login.isUpdating)
                    }
                }
                if let reason = login.errorMessage {
                    Text(verbatim: coordinator.text(reason))
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                Picker("语言", selection: $preferences.value.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }
                Picker("外观", selection: $preferences.value.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                Toggle("显示菜单栏图标", isOn: $preferences.value.showMenuBar)
                Toggle("关闭主窗口后继续运行", isOn: $preferences.value.keepRunning)
            }
            Section {
                Button("隐私政策") { showingPrivacyPolicy = true }
            }
        }
    }

    private var scanning: some View {
        @Bindable var preferences = coordinator.preferences
        return Section {
            Toggle("打开 App 后自动扫描", isOn: $preferences.value.autoScanOnOpen)
            Toggle("连接外置磁盘后自动扫描", isOn: $preferences.value.autoScanOnMount)
            Toggle("自动扫描时优先增量扫描", isOn: $preferences.value.incrementalScan)
            Toggle("扫描 .DS_Store", isOn: $preferences.value.scanDSStore)
            Toggle("扫描 AppleDouble", isOn: $preferences.value.scanAppleDouble)
        }
    }

    private var cleanup: some View {
        @Bindable var preferences = coordinator.preferences
        return Group {
            Section {
                Toggle("自动扫描完成后清理", isOn: $preferences.value.cleanup.automatic)
                Toggle("清理前确认", isOn: $preferences.value.cleanup.requiresConfirmation)
            } footer: {
                Text("启动、登录和接盘后的自动扫描完成且无读取问题时，清理默认选中的文件。关闭确认后，清理会直接移入废纸篓。")
            }
            Section {
                Toggle("默认选择 .DS_Store", isOn: $preferences.value.selectDSStore)
                Toggle("默认选择 AppleDouble", isOn: Binding(
                    get: { preferences.value.selectAppleDouble },
                    set: { enabled in
                        if enabled && !preferences.value.acknowledgedAppleDouble {
                            showingAppleDoubleWarning = true
                        } else {
                            preferences.value.selectAppleDouble = enabled
                        }
                    }
                ))
                LabeledContent("清理方式") { Text("移入废纸篓") }
            }
        }
    }

    private var activity: some View {
        HStack {
            Button("查看操作记录…") { showingLog = true }
            Spacer()
            Button("清除操作记录…", role: .destructive) { confirmingClearLog = true }
                .disabled(coordinator.model.operationLog.entries.isEmpty)
        }
    }
}
