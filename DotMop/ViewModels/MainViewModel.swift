import AppKit
import Observation

@Observable
@MainActor
final class MainViewModel {
    enum RefreshScan: Hashable {
        case manual, startup, mount(URL), volumeChange
    }

    let preferences: PreferencesStore
    let operationLog: OperationLogStore
    private(set) var disks: [DiskInfo] = []
    private(set) var folderScopes: [String: VolumeBoundary] = [:]
    var selectedID: String?
    var errorMessage: String?
    private(set) var isRefreshing = false
    private(set) var isChoosingFolder = false
    private(set) var scans: [String: DiskScanState] = [:]
    var pendingCleanup: CleanupRequest?
    var cleanupReport: CleanupReport?
    var cleanupConfirmationIsVisible = false
    private(set) var cleaningDiskID: String?
    private(set) var cleanupProgress: CleanupProgress?
    private(set) var ejectingDiskID: String?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var scansAfterRefresh: Set<RefreshScan> = []
    @ObservationIgnored private let discoverDisks: @Sendable () -> [DiskInfo]
    @ObservationIgnored private let verifyVolume: @Sendable (VolumeReference) throws -> Void
    @ObservationIgnored private let ejectVolume: @Sendable (VolumeReference) throws -> Void
    @ObservationIgnored private let cleanFiles: @Sendable (VolumeBoundary, [CleanableFile], (CleanupProgress) -> Void) -> CleanupResult
    @ObservationIgnored private let showAutomaticConfirmation: () -> Void
    @ObservationIgnored private var scanTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var scanPauses: [String: ScanPauseControl] = [:]
    @ObservationIgnored private var scanWhenIdle: [String: Bool] = [:]
    @ObservationIgnored private var automaticCleanupQueue: [String] = []
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var cleanupWorker: Task<CleanupResult, Never>?
    @ObservationIgnored private var cleanupCompletion: Task<Void, Never>?

    var selectedDisk: DiskInfo? { disks.first { $0.id == selectedID } }

    init(preferences: PreferencesStore,
         operationLog: OperationLogStore = OperationLogStore(),
         discoverDisks: @escaping @Sendable () -> [DiskInfo] = DiskService.discover,
         verifyVolume: @escaping @Sendable (VolumeReference) throws -> Void = DiskService.verifyBackupStatus,
         ejectVolume: @escaping @Sendable (VolumeReference) throws -> Void = {
             try $0.verify()
             try NSWorkspace.shared.unmountAndEjectDevice(at: $0.url)
         },
         cleanFiles: @escaping @Sendable (VolumeBoundary, [CleanableFile], (CleanupProgress) -> Void) -> CleanupResult = {
             CleanupService.run(boundary: $0, files: $1, onProgress: $2)
         },
         showAutomaticConfirmation: @escaping () -> Void = {}) {
        self.preferences = preferences
        self.operationLog = operationLog
        self.discoverDisks = discoverDisks
        self.verifyVolume = verifyVolume
        self.ejectVolume = ejectVolume
        self.cleanFiles = cleanFiles
        self.showAutomaticConfirmation = showAutomaticConfirmation
    }

    func start(autoScan: Bool) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) {
            [weak self] notification in
            let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                guard let self else { return }
                let scan = url.map(RefreshScan.mount) ?? .volumeChange
                self.refreshDisks(scan: self.preferences.value.autoScanOnMount ? scan : nil)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) {
            [weak self] notification in
            let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                if let url { self?.removeVolume(at: url) }
                self?.refreshDisks()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDisks(scan: self.preferences.value.autoScanOnMount ? .volumeChange : nil)
            }
        })
        refreshDisks(scan: autoScan ? .startup : nil)
    }

    func stop() {
        isStopping = true
        automaticCleanupQueue.removeAll()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        refreshGeneration += 1
        for task in scanTasks.values { task.cancel() }
        for pause in scanPauses.values { pause.resume() }
        cleanupWorker?.cancel()
    }

    func refreshDisks(scan: RefreshScan? = nil) {
        guard !isStopping else { return }
        if let scan { scansAfterRefresh.insert(scan) }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        Task {
            let discovered = await Task.detached(priority: .utility) { [discoverDisks] in
                discoverDisks()
            }.value
            guard generation == refreshGeneration else { return }
            let previousVolumes = Dictionary(uniqueKeysWithValues: disks.map { ($0.id, $0.volume) })
            let discoveredIDs = Set(discovered.map(\.id))
            for disk in disks where !discoveredIDs.contains(disk.id) {
                folderScopes.removeValue(forKey: disk.id)
                invalidateScan(for: disk.id)
            }
            disks = discovered
            for disk in disks {
                if let previous = previousVolumes[disk.id], previous != disk.volume {
                    invalidateScan(for: disk.id)
                }
            }
            if !disks.contains(where: { $0.id == selectedID }) {
                selectedID = disks.first?.id
            }
            let reasons = scansAfterRefresh
            scansAfterRefresh.removeAll()
            isRefreshing = false
            let mounted = reasons.compactMap { reason -> URL? in
                if case .mount(let url) = reason { return url }
                return nil
            }
            for disk in disks {
                let newVolume = previousVolumes[disk.id] != disk.volume
                let automatic = reasons.contains(.startup) || mounted.contains { ScopePath.same($0, disk.volume.url) }
                if automatic || reasons.contains(.manual) || (reasons.contains(.volumeChange) && newVolume) {
                    startScan(disk.id, automatically: automatic)
                }
            }
            processAutomaticCleanupQueue()
        }
    }

    func chooseFolder(for disk: DiskInfo) {
        guard !isChoosingFolder, cleaningDiskID != disk.id, ejectingDiskID != disk.id else { return }
        isChoosingFolder = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.resolvesAliases = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = requiresFolderReselection(disk) ? disk.volume.url : folderScopes[disk.id]?.root ?? disk.volume.url
        panel.prompt = text("选择")
        panel.message = text("仅扫描并清理所选文件夹及其子文件夹。")

        Task {
            defer {
                isChoosingFolder = false
                processAutomaticCleanupQueue()
            }
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                let boundary = try await Task.detached(priority: .userInitiated) {
                    try VolumeBoundary(volume: disk.volume, root: url)
                }.value
                try setFolderScope(boundary, for: disk.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requiresFolderReselection(_ disk: DiskInfo) -> Bool {
        guard let scope = folderScopes[disk.id] else { return false }
        return scope.volume != disk.volume
    }

    func setFolderScope(_ boundary: VolumeBoundary, for id: String) throws {
        guard disks.first(where: { $0.id == id })?.volume == boundary.volume else {
            throw SafetyError.volumeChanged
        }
        guard cleaningDiskID != id, ejectingDiskID != id else { return }
        folderScopes[id] = ScopePath.same(boundary.root, boundary.volume.url) ? nil : boundary
        invalidateScan(for: id)
        startScan(id)
    }

    func scanWholeDisk(_ id: String) {
        guard cleaningDiskID != id, ejectingDiskID != id, folderScopes.removeValue(forKey: id) != nil else { return }
        invalidateScan(for: id)
        startScan(id)
    }

    private func removeVolume(at url: URL) {
        let disconnected = disks.filter { ScopePath.same($0.volume.url, url) }
        for disk in disconnected {
            folderScopes.removeValue(forKey: disk.id)
            invalidateScan(for: disk.id)
        }
        disks.removeAll { disk in disconnected.contains { $0.id == disk.id } }
        if !disks.contains(where: { $0.id == selectedID }) { selectedID = disks.first?.id }
    }

    func canEjectDisk(_ id: String) -> Bool {
        !isStopping && ejectingDiskID == nil && (cleaningDiskID == nil || cleaningDiskID == id) && pendingCleanup == nil
            && !cleanupConfirmationIsVisible && !isChoosingFolder
    }

    func ejectDisk(_ id: String) async {
        guard canEjectDisk(id), let disk = disks.first(where: { $0.id == id }) else { return }
        ejectingDiskID = id
        defer {
            ejectingDiskID = nil
            processAutomaticCleanupQueue()
        }
        automaticCleanupQueue.removeAll { $0 == id }
        scanWhenIdle.removeValue(forKey: id)
        if cleaningDiskID == id {
            cleanupWorker?.cancel()
            await cleanupCompletion?.value
        }
        if let task = scanTasks[id] {
            if let state = scans[id], state.phase.isActive || state.phase == .paused {
                state.phase = .cancelling
            }
            task.cancel()
            scanPauses[id]?.resume()
            await task.value
        }
        guard !isStopping, disks.contains(where: { $0.id == id && $0.volume == disk.volume }) else { return }
        do {
            let volume = disk.volume
            try await Task.detached(priority: .userInitiated) { [ejectVolume] in
                try ejectVolume(volume)
            }.value
            if disks.contains(where: { $0.id == id && $0.volume == volume }) {
                removeVolume(at: volume.url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshDisks()
    }

    func startScan(_ id: String, automatically: Bool = false) {
        guard !isStopping, let disk = disks.first(where: { $0.id == id }),
              !requiresFolderReselection(disk),
              cleaningDiskID != id, ejectingDiskID != id else { return }
        automaticCleanupQueue.removeAll { $0 == id }
        if pendingCleanup?.diskID == id { pendingCleanup = nil }
        guard scanTasks[id] == nil else {
            if scans[id] == nil { scanWhenIdle[id] = automatically }
            return
        }
        let state = scans[id] ?? DiskScanState()
        scans[id] = state
        state.begin()
        let settings = preferences.value
        let options = ScanOptions(dsStore: settings.scanDSStore, appleDouble: settings.scanAppleDouble)
        let volume = disk.volume
        let folder = folderScopes[id]
        let pause = ScanPauseControl()
        scanPauses[id] = pause
        let (events, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        scanTasks[id] = Task.detached(priority: .utility) { [verifyVolume] in
            defer { continuation.finish() }
            var files: [CleanableFile] = []
            var progress = ScanSummary()
            var scannedBoundary: VolumeBoundary?
            do {
                try Task.checkCancellation()
                try verifyVolume(volume)
                let boundary: VolumeBoundary
                if let folder {
                    guard folder.volume == volume else { throw SafetyError.scopeChanged }
                    boundary = folder
                } else {
                    boundary = try VolumeBoundary(volume: volume, root: volume.url)
                }
                scannedBoundary = boundary
                let summary = try DirectoryScanIndex.scan(boundary: boundary, options: options,
                                                          useIndex: settings.incrementalScan, allowReuse: automatically,
                                                          pause: pause, onPaused: {
                    continuation.yield(.paused(progress, boundary, files))
                }) { batch in
                    files.append(contentsOf: batch.files)
                    progress = batch.summary
                    continuation.yield(.progress(batch.summary))
                }
                try Task.checkCancellation()
                continuation.yield(.finished(summary, boundary, files))
            } catch let error where error is CancellationError || Task.isCancelled {
                continuation.yield(.cancelled(progress, scannedBoundary, files))
            } catch let error where isFileAccessDenied(error) {
                continuation.yield(.accessDenied)
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
        }

        Task {
            for await event in events {
                guard scans[id] === state else { continue }
                switch event {
                case .progress(let summary):
                    state.updateProgress(summary)
                case .paused(let summary, let boundary, let files):
                    if state.phase == .pausing { state.retainPaused(summary, boundary: boundary, files: files) }
                case .finished(let summary, let boundary, let files):
                    if state.phase == .cancelling {
                        state.retainCancelled(summary, boundary: boundary, files: files)
                        continue
                    }
                    state.finish(summary, boundary: boundary, files: files, selectDSStore: settings.selectsByDefault(.dsStore),
                                 selectAppleDouble: settings.selectsByDefault(.appleDouble))
                    operationLog.scan(disk: disk.name, summary: summary)
                case .cancelled(let summary, let boundary, let files):
                    state.retainCancelled(summary, boundary: boundary, files: files)
                case .accessDenied: state.discard(phase: .accessDenied)
                case .failed(let reason): state.discard(phase: .failed(reason))
                }
            }
            scanTasks.removeValue(forKey: id)
            scanPauses.removeValue(forKey: id)
            if let automatic = scanWhenIdle.removeValue(forKey: id) {
                startScan(id, automatically: automatic)
            } else if !isStopping, ejectingDiskID != id, automatically, settings.cleanup.automatic, preferences.value.cleanup.automatic,
                      scans[id] === state, state.phase == .finished, !state.changedSelectionWhilePaused,
                      state.summary.issues.total == 0 {
                automaticCleanupQueue.append(id)
                processAutomaticCleanupQueue()
            }
        }
    }

    func pauseScan(_ id: String) {
        guard let state = scans[id], state.phase == .scanning, let pause = scanPauses[id] else { return }
        state.phase = .pausing
        pause.requestPause()
    }

    func resumeScan(_ id: String) {
        guard cleaningDiskID != id, pendingCleanup?.diskID != id,
              let state = scans[id], state.phase == .paused, let pause = scanPauses[id] else { return }
        state.phase = .scanning
        pause.resume()
    }

    func cancelScan(_ id: String) {
        guard cleaningDiskID != id, pendingCleanup?.diskID != id,
              let state = scans[id], state.phase == .paused || state.phase == .pausing else { return }
        state.phase = .cancelling
        scanTasks[id]?.cancel()
        scanPauses[id]?.resume()
    }

    func prepareCleanup(for id: String, visibleFiles: [CleanableFile]? = nil, method: CleanupMethod = .trash) {
        guard ejectingDiskID == nil, pendingCleanup == nil, !cleanupConfirmationIsVisible,
              cleanupReport == nil, cleaningDiskID == nil,
              let request = cleanupRequest(for: id, visibleFiles: visibleFiles, method: method) else { return }
        automaticCleanupQueue.removeAll { $0 == id }
        if method == .permanentDelete || preferences.value.cleanup.requiresConfirmation {
            pendingCleanup = request
        } else {
            startCleanup(request)
        }
    }

    func processAutomaticCleanupQueue() {
        guard !isStopping else { return }
        let settings = preferences.value.cleanup
        guard settings.automatic else {
            automaticCleanupQueue.removeAll()
            if pendingCleanup?.automatic == true { pendingCleanup = nil }
            return
        }
        guard ejectingDiskID == nil, pendingCleanup == nil, !cleanupConfirmationIsVisible, cleanupReport == nil,
              cleaningDiskID == nil, !isChoosingFolder else { return }
        while !automaticCleanupQueue.isEmpty {
            let id = automaticCleanupQueue.removeFirst()
            guard let request = cleanupRequest(for: id, automatic: true) else { continue }
            if settings.requiresConfirmation {
                selectedID = id
                pendingCleanup = request
                showAutomaticConfirmation()
            } else {
                startCleanup(request)
            }
            return
        }
    }

    private func cleanupRequest(for id: String, visibleFiles: [CleanableFile]? = nil,
                                automatic: Bool = false, method: CleanupMethod = .trash) -> CleanupRequest? {
        guard let disk = disks.first(where: { $0.id == id && !$0.isReadOnly }),
              let state = scans[id], state.phase.allowsCleanup(automatic: automatic),
              let boundary = state.boundary, state.selection.count > 0 else { return nil }
        let settings = preferences.value
        let selected = state.files.filter {
            state.selected.contains($0.id) && (!automatic || settings.selectsByDefault($0.kind))
        }
        guard !selected.isEmpty else { return nil }
        let hiddenSelection = visibleFiles.map { state.selected.subtracting($0.lazy.map(\.id)) } ?? []
        return CleanupRequest(diskID: id, diskName: disk.name, boundary: boundary,
                              files: selected, hiddenSelection: hiddenSelection, automatic: automatic, method: method)
    }

    func confirmCleanup(_ request: CleanupRequest) {
        guard pendingCleanup?.id == request.id else { return }
        pendingCleanup = nil
        if request.automatic && !preferences.value.cleanup.automatic { return }
        startCleanup(request)
    }

    private func startCleanup(_ request: CleanupRequest) {
        guard !isStopping, ejectingDiskID == nil, cleaningDiskID == nil,
              let disk = disks.first(where: { $0.id == request.diskID && !$0.isReadOnly }),
              disk.volume == request.boundary.volume,
              let state = scans[request.diskID], state.phase.allowsCleanup(automatic: request.automatic),
              state.boundary == request.boundary else {
            errorMessage = SafetyError.scopeChanged.localizedDescription
            return
        }

        cleaningDiskID = request.diskID
        cleanupProgress = CleanupProgress(processed: 0, total: request.files.count)
        let (progress, continuation) = AsyncStream<CleanupProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task.detached(priority: .userInitiated) { [verifyVolume, cleanFiles] in
            defer { continuation.finish() }
            do {
                try Task.checkCancellation()
                try verifyVolume(disk.volume)
                if request.method == .permanentDelete {
                    return CleanupService.run(boundary: request.boundary, files: request.files, method: request.method,
                                              onProgress: {
                        continuation.yield($0)
                    })
                }
                return cleanFiles(request.boundary, request.files) { continuation.yield($0) }
            } catch is CancellationError {
                var result = CleanupResult()
                result.unprocessed = request.files.count
                return result
            } catch {
                let disposition: CleanupIssue.Disposition = isFileAccessDenied(error) ? .retry : .rescan
                return CleanupResult.skipped(request, reason: error.localizedDescription, disposition: disposition)
            }
        }
        cleanupWorker = worker
        cleanupCompletion = Task {
            for await update in progress { cleanupProgress = update }
            let result = await worker.value
            if scans[request.diskID] === state { state.applyCleanup(result) }
            operationLog.cleanup(disk: request.diskName, result: result, automatic: request.automatic,
                                 method: request.method)
            if !request.automatic {
                cleanupReport = CleanupReport(diskName: request.diskName, result: result, method: request.method)
            }
            cleaningDiskID = nil
            cleanupProgress = nil
            cleanupWorker = nil
            cleanupCompletion = nil
            if result.skipped > 0 || result.deleted.count > 0 { refreshDisks() }
            processAutomaticCleanupQueue()
        }
    }

    func stopCleanupForQuit() async {
        isStopping = true
        automaticCleanupQueue.removeAll()
        cleanupWorker?.cancel()
        await cleanupCompletion?.value
    }

    func reveal(_ file: CleanableFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func revealRecoveryFolder(_ recovery: RetainedRecovery) -> Bool {
        guard let location = recovery.location(on: disks.map(\.volume)),
              (try? location.volume.verify()) != nil,
              let folder = try? OpenFile(at: location.url, directory: true),
              let filesystem = try? folder.filesystem(),
              FilesystemIdentity(filesystem) == location.volume.filesystemID else {
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([location.url])
        return true
    }

    private func invalidateScan(for id: String) {
        scans.removeValue(forKey: id)
        scanWhenIdle.removeValue(forKey: id)
        automaticCleanupQueue.removeAll { $0 == id }
        scanTasks[id]?.cancel()
        scanPauses[id]?.resume()
        if pendingCleanup?.diskID == id { pendingCleanup = nil }
        if cleaningDiskID == id { cleanupWorker?.cancel() }
    }

    private func text(_ key: String) -> String {
        L10n.text(key, language: preferences.value.language)
    }
}
