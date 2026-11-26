import SwiftUI

struct ScanWorkspaceView: View {
    private static let pageSize = 500

    private enum Filter: CaseIterable {
        case all, dsStore, appleDouble

        var title: LocalizedStringKey {
            switch self {
            case .all: "所有类型"
            case .dsStore: ".DS_Store"
            case .appleDouble: "AppleDouble"
            }
        }

        func matches(_ kind: FileKind) -> Bool {
            self == .all || (self == .dsStore && kind == .dsStore) || (self == .appleDouble && kind == .appleDouble)
        }
    }

    private struct SearchInput: Equatable, Sendable {
        let query: String
        let filesRevision: UUID?
    }

    private struct SearchResult {
        let input: SearchInput
        let files: [CleanableFile]
    }

    let model: MainViewModel
    let disk: DiskInfo
    let state: DiskScanState?
    @State private var showingIssues = false
    @State private var showingFileDetails = false
    @State private var showingAppleDoubleWarning = false
    @State private var pendingAppleDouble: Set<UUID> = []
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var searchResult: SearchResult?
    @State private var highlighted: UUID?
    @State private var page = 0

    private var phase: ScanPhase { state?.phase ?? .ready }
    private var isCleaning: Bool { model.cleaningDiskID == disk.id }
    private var canSelect: Bool {
        phase.allowsCleanup(automatic: false) && state?.boundary != nil && !isCleaning && model.ejectingDiskID == nil
    }
    private var showsResults: Bool { phase.hasResults }
    private var hasFilters: Bool { filter != .all || !query.isEmpty }
    private var searchInput: SearchInput { SearchInput(query: query, filesRevision: state?.filesRevision) }

    var body: some View {
        let input = searchInput
        let searching = !input.query.isEmpty && searchResult?.input != input
        let files = visibleFiles(searching: searching)
        let pageCount = max(1, (files.count + Self.pageSize - 1) / Self.pageSize)
        let currentPage = min(page, pageCount - 1)
        let first = currentPage * Self.pageSize
        let pageFiles = Array(files.dropFirst(first).prefix(Self.pageSize))
        let highlightedFile = highlighted.flatMap { id in pageFiles.first { $0.id == id } }
        VStack(spacing: 0) {
            ScanSummaryView(statistics: state?.summary.statistics ?? ScanStatistics(), selection: state?.selection ?? FileTally())
            Divider()
            if showsResults, let state, !state.files.isEmpty {
                controls(files, state: state)
                Divider()
                if searching {
                    ProgressView("正在搜索…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if files.isEmpty {
                    ContentUnavailableView("没有匹配的文件", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FileListView(files: pageFiles, state: state, canSelect: canSelect, highlighted: $highlighted,
                                 changeSelection: changeSelection, reveal: model.reveal)
                    if pageCount > 1 {
                        Divider()
                        pageControls(currentPage, count: pageCount)
                    }
                }
            } else {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                if phase.isActive || showsResults { status }
                if hasFilters, !searching, let state, !model.preferences.value.cleanup.requiresConfirmation {
                    let hidden = state.selection.count - files.lazy.filter { state.selected.contains($0.id) }.count
                    if hidden > 0 {
                        Text("当前筛选隐藏了 \(hidden) 个已选文件，它们也会移入废纸篓。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let highlightedFile, let issue = state?.cleanupIssues[highlightedFile.id] {
                    let reason = L10n.text(issue.file.reason, language: model.preferences.value.language)
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text(verbatim: reason))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer(files: files, highlightedFile: highlightedFile, searching: searching)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .sheet(isPresented: $showingIssues) {
            IssueListView(title: "扫描问题", issues: state?.summary.issues.samples ?? [],
                          total: state?.summary.issues.total ?? 0, language: model.preferences.value.language)
        }
        .appleDoubleWarning(isPresented: $showingAppleDoubleWarning) {
            model.preferences.value.acknowledgedAppleDouble = true
            if canSelect, let state {
                state.setSelected(state.files.filter { pendingAppleDouble.contains($0.id) }, to: true)
            }
            pendingAppleDouble.removeAll()
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .scanning { resetPage() }
        }
        .onChange(of: query) { resetPage() }
        .onChange(of: filter) { resetPage() }
        .onChange(of: highlighted) { showingFileDetails = false }
        .task(id: input) { await search(input) }
    }

    private func visibleFiles(searching: Bool) -> [CleanableFile] {
        guard showsResults, let state, !searching else { return [] }
        let matching = query.isEmpty ? state.files : searchResult?.files ?? []
        return filter == .all ? matching : matching.filter { filter.matches($0.kind) }
    }

    private func search(_ input: SearchInput) async {
        guard !Task.isCancelled, searchInput == input else { return }
        guard showsResults, !input.query.isEmpty, let state, !state.files.isEmpty else {
            searchResult = nil
            return
        }
        do {
            if searchResult?.input.query != input.query { try await Task.sleep(for: .milliseconds(90)) }
            try Task.checkCancellation()
            guard searchInput == input else { return }
            let files = state.files
            let worker = Task.detached(priority: .userInitiated) { () -> [CleanableFile] in
                var matches: [CleanableFile] = []
                for file in files {
                    if Task.isCancelled { return [] }
                    if file.matchesSearch(input.query) { matches.append(file) }
                }
                return matches
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard searchInput == input else { return }
            searchResult = SearchResult(input: input, files: matches)
        } catch {
            // A newer query or scan snapshot replaced this search.
        }
    }

    private func pageControls(_ current: Int, count: Int) -> some View {
        HStack(spacing: 12) {
            Spacer()
            Button("上一页") { page = current - 1; highlighted = nil }
                .disabled(current == 0)
            Text("第 \(current + 1) / \(count) 页").monospacedDigit()
            Button("下一页") { page = current + 1; highlighted = nil }
                .disabled(current + 1 == count)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func resetPage() {
        page = 0
        highlighted = nil
    }

    private func controls(_ files: [CleanableFile], state: DiskScanState) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Button("全选") { changeSelection(true, files) }
                    .help("全选匹配结果")
                    .disabled(!canSelect || !files.contains { !state.selected.contains($0.id) && state.canSelect($0) })
                Button("取消全选") { changeSelection(false, files) }
                    .help("取消选择匹配结果")
                    .disabled(!canSelect || state.selection.count == 0 || !files.contains { state.selected.contains($0.id) })
            }
            .buttonStyle(.bordered)
            .fixedSize()

            Spacer(minLength: 3)
            Picker("文件类型", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { option in Text(option.title).tag(option) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("文件类型"))

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索名称或路径", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("search-files")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Label("清除搜索", systemImage: "xmark.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(maxWidth: 177)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var empty: some View {
        switch phase {
        case .ready:
            if model.requiresFolderReselection(disk) {
                ContentUnavailableView("请重新选择扫描范围", systemImage: "folder.badge.questionmark",
                                       description: Text("磁盘的挂载路径已变化。请在「扫描范围」中重新选择文件夹，或选择扫描整块磁盘。"))
            } else {
                ContentUnavailableView("等待扫描", systemImage: "magnifyingglass")
            }
        case .scanning, .pausing, .cancelling:
            Color.clear
        case .paused:
            ContentUnavailableView("扫描已暂停", systemImage: "pause.circle")
        case .cancelled:
            ContentUnavailableView("扫描已停止", systemImage: "stop.circle")
        case .accessDenied:
            ContentUnavailableView(
                "无法读取扫描范围",
                systemImage: "lock.shield",
                description: Text("请检查文件夹读取权限，以及 macOS「系统设置 → 隐私与安全性 → 文件与文件夹」中 DotMop 的可移动宗卷权限，然后重新扫描。")
            )
        case .failed(let reason):
            ContentUnavailableView("扫描未完成", systemImage: "exclamationmark.triangle",
                                   description: Text(verbatim: L10n.text(reason, language: model.preferences.value.language)))
        case .finished:
            if let state, state.summary.issues.total > 0 {
                ContentUnavailableView("扫描部分完成", systemImage: "exclamationmark.triangle",
                                       description: Text("在可读取的位置未发现待清理文件。"))
            } else {
                ContentUnavailableView("没有待清理文件", systemImage: "checkmark.circle")
            }
        }
    }

    private var scanStatus: LocalizedStringKey {
        switch phase {
        case .pausing: "正在暂停…"
        case .paused: "扫描已暂停"
        case .cancelling: "正在停止…"
        case .cancelled: "扫描已停止"
        default: "正在扫描…"
        }
    }

    private var status: some View {
        VStack(spacing: 5) {
            scanStatusRow
            if isCleaning, let progress = model.cleanupProgress {
                if progress.isSubmittingToTrash {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel(Text("正在移入废纸篓…"))
                } else {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total))
                        .progressViewStyle(.linear)
                        .accessibilityLabel(Text("正在清理…"))
                }
            } else if phase.isActive {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text(scanStatus))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }

    private var scanStatusRow: some View {
        HStack(spacing: 5) {
            if isCleaning {
                Text(model.cleanupProgress?.isSubmittingToTrash == true ? "正在移入废纸篓…" : "正在清理…")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            } else if phase.isActive || phase == .paused || phase == .cancelled {
                Text(scanStatus)
            } else {
                if (state?.summary.issues.total ?? 0) > 0 {
                    Text("扫描部分完成")
                } else {
                    Text(state?.summary.incremental == true ? "增量扫描完成" : "扫描完成")
                }
            }
            Spacer()
            if isCleaning, let progress = model.cleanupProgress {
                Text("已处理 \(progress.processed) / \(progress.total) 项").monospacedDigit()
            } else if let state {
                if state.summary.issues.total > 0 {
                    Button("查看问题") { showingIssues = true }
                        .controlSize(.mini)
                }
                Text("已检查")
                Text(state.summary.visited, format: .number).monospacedDigit()
            }
        }
    }

    private func footer(files: [CleanableFile], highlightedFile: CleanableFile?, searching: Bool) -> some View {
        HStack(spacing: 9) {
            if phase.isActive {
                Button("暂停扫描") { model.pauseScan(disk.id) }
                    .disabled(phase != .scanning)
                if phase == .pausing {
                    Button("停止扫描") { model.cancelScan(disk.id) }
                }
            } else if phase == .paused {
                Button("继续扫描") { model.resumeScan(disk.id) }
                    .disabled(isCleaning)
                Button("停止扫描") { model.cancelScan(disk.id) }
                    .disabled(isCleaning)
            } else {
                Button("重新扫描") { model.startScan(disk.id) }
                    .disabled(isCleaning || model.ejectingDiskID == disk.id || model.requiresFolderReselection(disk))
            }
            Button("查看文件") {
                if let highlightedFile { model.reveal(highlightedFile) }
            }
            .disabled(highlightedFile == nil)
            Button {
                showingFileDetails = true
            } label: {
                Label("文件详情", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
            }
            .help("文件详情")
            .disabled(highlightedFile == nil)
            .popover(isPresented: $showingFileDetails) {
                if let highlightedFile { fileDetails(highlightedFile) }
            }
            Spacer(minLength: 3)
            let requiresConfirmation = model.preferences.value.cleanup.requiresConfirmation
            HStack(spacing: 4) {
                Button(requiresConfirmation ? "清理选中文件…" : "移入废纸篓") {
                    model.prepareCleanup(for: disk.id, visibleFiles: hasFilters ? files : nil)
                }
                .buttonStyle(.borderedProminent)
                Menu {
                    Button("永久删除…", role: .destructive) {
                        model.prepareCleanup(for: disk.id, visibleFiles: hasFilters ? files : nil, method: .permanentDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .fixedSize()
                .accessibilityLabel(Text("更多清理选项"))
                .help("更多清理选项")
            }
            .disabled(!canSelect || searching || disk.isReadOnly || model.cleaningDiskID != nil
                      || (state?.selection.count ?? 0) == 0)
        }
    }

    private func fileDetails(_ file: CleanableFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: file.name)
                .font(.headline)
                .textSelection(.enabled)
            Text(verbatim: file.url.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            LabeledContent("修改时间") {
                Text(file.modified, format: .dateTime.year().month().day().hour().minute().second())
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .environment(\.locale, model.preferences.value.language.locale)
    }

    private func changeSelection(_ enabled: Bool, _ files: [CleanableFile]) {
        guard canSelect, let state else { return }
        if enabled, !model.preferences.value.acknowledgedAppleDouble {
            state.setSelected(files.filter { $0.kind == .dsStore }, to: true)
            let sidecars = files.filter { $0.kind == .appleDouble && state.canSelect($0) }
            if !sidecars.isEmpty {
                pendingAppleDouble = Set(sidecars.map(\.id))
                showingAppleDoubleWarning = true
            }
        } else {
            state.setSelected(files, to: enabled)
        }
    }
}

struct IssueListView: View {
    let title: LocalizedStringKey
    let issues: [FileIssue]
    let total: Int
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if issues.count < total {
                Text("显示 \(issues.count) / \(total) 条问题").foregroundStyle(.secondary)
            }
            List(issues) { issue in
                IssueRow(issue: issue, language: language)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 310)
        .environment(\.locale, language.locale)
    }
}

struct IssueRow: View {
    let issue: FileIssue
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: L10n.text(issue.reason, language: language))
            Text(verbatim: issue.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
