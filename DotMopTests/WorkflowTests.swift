import AppKit
import Foundation
import os
import XCTest
@testable import DotMop

final class WorkflowTests: XCTestCase {
    @MainActor
    func testEjectStopsCleanupAndWaitsForWorkerBeforeCallingSystem() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try fixtureDisk(named: "Eject", under: root)
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.value.cleanup.requiresConfirmation = false
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let allowCleanupExit = DispatchSemaphore(value: 0)
        let model = MainViewModel(preferences: preferences, operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: {
            events.withLock { $0.contains("ejected") ? [] : [disk] }
        }, verifyVolume: { try $0.verify() }, ejectVolume: { volume in
            XCTAssertEqual(volume, disk.volume)
            events.withLock { $0.append("ejected") }
        }, cleanFiles: { _, _, _ in
            events.withLock { $0.append("cleaning") }
            if allowCleanupExit.wait(timeout: .now() + 4) == .timedOut {
                XCTFail("Cleanup was not released.")
            }
            XCTAssertTrue(Task.isCancelled)
            events.withLock { $0.append("closed") }
            return CleanupResult()
        })
        model.refreshDisks(scan: .manual)
        defer { model.stop() }
        _ = try await waitForScan(disk.id, in: model)
        model.prepareCleanup(for: disk.id)
        for _ in 0..<400 where events.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(events.withLock { $0 }, ["cleaning"])

        let eject = Task { await model.ejectDisk(disk.id) }
        for _ in 0..<400 where model.ejectingDiskID == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.ejectingDiskID, disk.id)
        XCTAssertEqual(events.withLock { $0 }, ["cleaning"])
        allowCleanupExit.signal()
        await eject.value
        XCTAssertEqual(events.withLock { $0 }, ["cleaning", "closed", "ejected"])
        XCTAssertNil(model.cleaningDiskID)
        XCTAssertTrue(model.disks.isEmpty)
    }

    @MainActor
    func testSelectionDefaultsAndByteCount() throws {
        try withFixture { root in
            let boundary = try fixtureBoundary(root)
            try Data([1, 2, 3]).write(to: root.appending(path: ".DS_Store"))
            try appleDoubleFixture.write(to: root.appending(path: "._photo"))
            let state = DiskScanState()
            let defaults = Preferences()
            state.begin()
            _ = try ScannerService.scan(boundary: boundary, options: ScanOptions()) { batch in
                state.consume(batch, selectDSStore: defaults.selectDSStore,
                              selectAppleDouble: defaults.selectAppleDouble && defaults.acknowledgedAppleDouble)
            }
            let sidecar = try XCTUnwrap(state.files.first { $0.kind == .appleDouble })
            XCTAssertFalse(state.selected.contains(sidecar.id))
            XCTAssertEqual(state.selection, FileTally(count: 1, bytes: 3))
            state.setSelected([sidecar], to: true)
            XCTAssertEqual(state.selection, FileTally(count: 2, bytes: 45))
            state.setSelected(state.files, to: false)
            XCTAssertEqual(state.selection, FileTally())
        }
    }

    @MainActor
    func testCleanupKeepsRetryableAndUnprocessedSelections() throws {
        try withFixture { root in
            for name in ["a", "b", "c", "d"] {
                try appleDoubleFixture.write(to: root.appending(path: "._" + name))
            }
            let boundary = try fixtureBoundary(root)
            let state = DiskScanState()
            _ = try ScannerService.scan(boundary: boundary, options: ScanOptions()) {
                state.consume($0, selectDSStore: false, selectAppleDouble: true)
            }
            let files = Dictionary(uniqueKeysWithValues: state.files.map { ($0.name, $0) })
            let moved = try XCTUnwrap(files["._a"])
            let retry = try XCTUnwrap(files["._b"])
            let replaced = try XCTUnwrap(files["._c"])
            let unprocessed = try XCTUnwrap(files["._d"])
            var result = CleanupResult()
            result.recordMoved(moved)
            result.record(retry, outcome: .failed, reason: "Permission denied")
            result.record(replaced, outcome: .skipped, reason: "Changed", disposition: .rescan)
            state.applyCleanup(result)
            XCTAssertEqual(state.selected, [retry.id, unprocessed.id])
            XCTAssertEqual(state.selection, FileTally(count: 2, bytes: 84))
        }
    }

    @MainActor
    func testStartupAndMountScanWithoutSavedAuthorization() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixtureDisk(named: "First", under: root)
        let second = try fixtureDisk(named: "Second", under: root)
        let connected = OSAllocatedUnfairLock(initialState: [first])
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let model = MainViewModel(preferences: PreferencesStore(defaults: defaults),
                                  operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { connected.withLock { $0 } },
                                  verifyVolume: { try $0.verify() })
        model.start(autoScan: true)
        defer { model.stop() }

        let firstScan = try await waitForScan(first.id, in: model)
        XCTAssertEqual(firstScan.phase, .finished)
        let firstFiles = firstScan.files.map(\.id)
        XCTAssertEqual(firstFiles.count, 1)
        XCTAssertEqual(firstScan.selection, FileTally(count: 1, bytes: 3))

        connected.withLock { $0.append(second) }
        model.refreshDisks(scan: .mount(second.volume.url))
        let secondScan = try await waitForScan(second.id, in: model)
        XCTAssertEqual(secondScan.phase, .finished)
        XCTAssertEqual(secondScan.files.map(\.url), [second.volume.url.appending(path: ".DS_Store")])
        XCTAssertEqual(model.scans[first.id]?.files.map(\.id), firstFiles)
        XCTAssertNil(model.pendingCleanup)
        XCTAssertFalse(model.operationLog.entries.contains { $0.kind == .cleanup })
    }

    @MainActor
    func testRenamedVolumeRequiresExplicitScopeSelection() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try fixtureDisk(named: "Before", under: root)
        let folder = disk.volume.url.appending(path: "Selected", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([7]).write(to: folder.appending(path: ".DS_Store"))
        let connected = OSAllocatedUnfairLock(initialState: [disk])
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let model = MainViewModel(preferences: PreferencesStore(defaults: defaults),
                                  operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { connected.withLock { $0 } }, verifyVolume: { try $0.verify() })
        defer { model.stop() }
        model.refreshDisks(scan: .manual)
        _ = try await waitForScan(disk.id, in: model)
        try model.setFolderScope(VolumeBoundary(volume: disk.volume, root: folder), for: disk.id)
        let scoped = try await waitForScan(disk.id, in: model)
        XCTAssertEqual(scoped.files.map(\.relativePath), [[".DS_Store"]])
        XCTAssertEqual(scoped.boundary?.root, folder)

        let newPath = root.appending(path: "After", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: disk.volume.url, to: newPath)
        let newVolume = try VolumeReference(url: newPath, persistentID: disk.volume.persistentID)
        let renamed = DiskInfo(volume: newVolume, name: "After", format: disk.format,
                               totalBytes: nil, availableBytes: nil, isReadOnly: false)
        XCTAssertEqual(renamed.id, disk.id)
        connected.withLock { $0 = [renamed] }
        model.preferences.value.cleanup.automatic = true
        model.refreshDisks(scan: .mount(newPath))
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.disks, [renamed])
        XCTAssertTrue(model.requiresFolderReselection(renamed))
        model.startScan(renamed.id)
        XCTAssertNil(model.scans[renamed.id])
        XCTAssertNil(model.pendingCleanup)

        let newFolder = newPath.appending(path: "Selected", directoryHint: .isDirectory)
        try model.setFolderScope(VolumeBoundary(volume: newVolume, root: newFolder), for: renamed.id)
        let rescanned = try await waitForScan(renamed.id, in: model)
        XCTAssertFalse(model.requiresFolderReselection(renamed))
        XCTAssertEqual(rescanned.files.map(\.url), [newFolder.appending(path: ".DS_Store")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath.appending(path: ".DS_Store").path))
        XCTAssertNil(model.pendingCleanup)
    }

    @MainActor
    func testAutomaticTrashFailureLeavesPersistentRecoveryNotice() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try fixtureDisk(named: "Recovery", under: root)
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.value.cleanup.automatic = true
        preferences.value.cleanup.requiresConfirmation = false
        let log = OperationLogStore(defaults: defaults)
        let model = MainViewModel(preferences: preferences, operationLog: log, discoverDisks: { [disk] },
                                  verifyVolume: { try $0.verify() },
                                  cleanFiles: { boundary, files, progress in
            CleanupService.run(boundary: boundary, files: files, trashFolder: { _ in throw POSIXError(.EPERM) },
                               onProgress: progress)
        })
        defer { model.stop() }
        model.refreshDisks(scan: .startup)
        try await waitForCleanup(disk.name, in: model)
        XCTAssertNil(model.cleanupReport)
        XCTAssertTrue(model.scans[disk.id]?.files.isEmpty == true)
        for _ in 0..<30 { log.scan(disk: disk.name, summary: ScanSummary()) }
        let reloaded = OperationLogStore(defaults: defaults)
        let entry = try XCTUnwrap(reloaded.pendingRecovery)
        XCTAssertEqual(entry.automatic, true)
        XCTAssertEqual(entry.retainedRecovery?.tally, FileTally(count: 1, bytes: 3))
        XCTAssertEqual(entry.retainedRecovery?.location(on: [disk.volume])?.url, entry.recoveryFolder)
        XCTAssertEqual(entry.failed, 0)
        reloaded.dismissRecoveryNotice(entry.id)
        let afterDismissal = OperationLogStore(defaults: defaults)
        XCTAssertNil(afterDismissal.pendingRecovery)
        XCTAssertTrue(afterDismissal.entries.contains { $0.id == entry.id })
    }

    @MainActor
    func testAutomaticStartupAndMountMoveDefaultSelectionWithoutConfirmation() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let startup = try fixtureDisk(named: "Startup", under: root)
        let later = try fixtureDisk(named: "Later", under: root)
        let unrelated = try fixtureDisk(named: "Unrelated", under: root)
        let sidecar = later.volume.url.appending(path: "._photo")
        try appleDoubleFixture.write(to: sidecar)
        let connected = OSAllocatedUnfairLock(initialState: [startup])
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.value.cleanup = Preferences.Cleanup(automatic: true, requiresConfirmation: false)
        preferences.value.selectAppleDouble = true
        let model = MainViewModel(preferences: preferences, operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { connected.withLock { $0 } },
                                  verifyVolume: { try $0.verify() },
                                  cleanFiles: Self.moveToFixtureTrash,
                                  showAutomaticConfirmation: { XCTFail("Confirmation was disabled.") })
        model.start(autoScan: true)
        defer { model.stop() }
        try await waitForCleanup(startup.name, in: model)

        connected.withLock { $0 += [later, unrelated] }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil,
                                                   userInfo: [NSWorkspace.volumeURLUserInfoKey: later.volume.url])
        try await waitForCleanup(later.name, in: model)
        XCTAssertNil(model.pendingCleanup)
        XCTAssertNil(model.cleanupReport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        for disk in [startup, later] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: disk.volume.url.appending(path: ".DS_Store").path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.volume.url.appending(path: ".DS_Store").path))
        let log = OperationLogStore(defaults: defaults)
        let cleanups = log.entries.filter { $0.kind == .cleanup }
        XCTAssertEqual(cleanups.map(\.diskName), [later.name, startup.name])
        XCTAssertTrue(cleanups.allSatisfy { $0.automatic == true && $0.tally.count == 1 && $0.recoveryFolder != nil })
    }

    @MainActor
    func testQueuedAutomaticConfirmationsDoNotMoveUntilConfirmed() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disks = try [fixtureDisk(named: "First", under: root), fixtureDisk(named: "Second", under: root)]
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.value.cleanup.automatic = true
        var presentations = 0
        let model = MainViewModel(preferences: preferences, operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { disks }, verifyVolume: { try $0.verify() },
                                  cleanFiles: Self.moveToFixtureTrash,
                                  showAutomaticConfirmation: { presentations += 1 })
        model.start(autoScan: true)
        defer { model.stop() }
        for disk in disks { _ = try await waitForScan(disk.id, in: model) }
        let first = try XCTUnwrap(model.pendingCleanup)
        XCTAssertTrue(first.automatic)
        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(disks.allSatisfy { FileManager.default.fileExists(atPath: $0.volume.url.appending(path: ".DS_Store").path) })
        model.pendingCleanup = nil
        model.processAutomaticCleanupQueue()
        let second = try XCTUnwrap(model.pendingCleanup)
        XCTAssertNotEqual(first.diskID, second.diskID)
        XCTAssertEqual(presentations, 2)
        model.confirmCleanup(second)
        try await waitForCleanup(second.diskName, in: model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.files[0].url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.files[0].url.path))
    }

    @MainActor
    func testPermanentDeletionAlwaysWaitsForConfirmation() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try fixtureDisk(named: "Permanent", under: root)
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.value.cleanup.requiresConfirmation = false
        let candidateURL = disk.volume.url.appending(path: ".DS_Store")
        let model = MainViewModel(preferences: preferences, operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: {
            [DiskInfo(volume: disk.volume, name: disk.name, format: disk.format, totalBytes: 100,
                     availableBytes: FileManager.default.fileExists(atPath: candidateURL.path) ? 10 : 13,
                     isReadOnly: false)]
        }, verifyVolume: { try $0.verify() })
        model.refreshDisks(scan: .manual)
        defer { model.stop() }
        let scan = try await waitForScan(disk.id, in: model)
        let candidate = try XCTUnwrap(scan.files.first)

        model.prepareCleanup(for: disk.id, visibleFiles: [], method: .permanentDelete)
        let cancelled = try XCTUnwrap(model.pendingCleanup)
        XCTAssertEqual(cancelled.hiddenSelection, [candidate.id])
        XCTAssertNil(model.cleaningDiskID)
        model.pendingCleanup = nil
        model.confirmCleanup(cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.url.path))

        model.prepareCleanup(for: disk.id, method: .permanentDelete)
        model.confirmCleanup(try XCTUnwrap(model.pendingCleanup))
        try await waitForCleanup(disk.name, in: model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.url.path))
        XCTAssertTrue(scan.files.isEmpty)
        XCTAssertEqual(model.cleanupReport?.result.deleted.count, 1)
        let restored = OperationLogStore(defaults: defaults)
        XCTAssertEqual(restored.entries.first?.method, .permanentDelete)
        XCTAssertEqual(restored.entries.first?.tally.count, 1)
        for _ in 0..<100 where model.disks.first?.availableBytes != 13 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.disks.first?.availableBytes, 13)
    }

    @MainActor
    func testManualScanOnlyAndDirectManualCleanupWhenConfirmationIsOff() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try fixtureDisk(named: "Manual", under: root)
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.value.cleanup = Preferences.Cleanup(automatic: true, requiresConfirmation: false)
        let model = MainViewModel(preferences: preferences, operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { [disk] }, verifyVolume: { try $0.verify() },
                                  cleanFiles: Self.moveToFixtureTrash)
        model.refreshDisks(scan: .manual)
        defer { model.stop() }
        let scan = try await waitForScan(disk.id, in: model)
        let candidate = try XCTUnwrap(scan.files.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.url.path))
        XCTAssertNil(model.cleaningDiskID)
        model.prepareCleanup(for: disk.id)
        XCTAssertNil(model.pendingCleanup)
        try await waitForCleanup(disk.name, in: model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.url.path))
        XCTAssertEqual(model.cleanupReport?.result.moved.count, 1)
        XCTAssertEqual(model.operationLog.entries.first?.automatic, false)
    }

    @MainActor
    func testAutomaticCleanupLeavesReadOnlyAndPartiallyScannedDisksAlone() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = try fixtureDisk(named: "Partial", under: root)
        let unreadable = partial.volume.url.appending(path: "Unreadable", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o000])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        let readOnly = try fixtureDisk(named: "Read Only", under: root, isReadOnly: true)
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.value.cleanup = Preferences.Cleanup(automatic: true, requiresConfirmation: false)
        let model = MainViewModel(preferences: preferences, operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { [partial, readOnly] }, verifyVolume: { try $0.verify() },
                                  cleanFiles: Self.moveToFixtureTrash)
        model.start(autoScan: true)
        defer { model.stop() }
        let partialScan = try await waitForScan(partial.id, in: model)
        let readOnlyScan = try await waitForScan(readOnly.id, in: model)
        XCTAssertEqual(partialScan.summary.issues.total, 1)
        XCTAssertEqual(readOnlyScan.summary.issues.total, 0)
        for scan in [partialScan, readOnlyScan] {
            let file = try XCTUnwrap(scan.files.first)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        }
        XCTAssertNil(model.cleaningDiskID)
        XCTAssertNil(model.pendingCleanup)
        XCTAssertFalse(model.operationLog.entries.contains { $0.kind == .cleanup })
    }

    @MainActor
    func testCleanupConfirmationIncludesFilteredOutSelection() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try fixtureDisk(named: "Drive", under: root)
        let child = disk.volume.url.appending(path: "Photo Album", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try appleDoubleFixture.write(to: child.appending(path: "._photo"))
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let model = MainViewModel(preferences: PreferencesStore(defaults: defaults),
                                  operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { [disk] },
                                  verifyVolume: { try $0.verify() })
        model.start(autoScan: true)
        defer { model.stop() }

        let state = try await waitForScan(disk.id, in: model)
        let sidecar = try XCTUnwrap(state.files.first { $0.kind == .appleDouble })
        let dsStore = try XCTUnwrap(state.files.first { $0.kind == .dsStore })
        XCTAssertTrue(sidecar.matchesSearch("/PHOTO ALBUM/"))
        XCTAssertTrue(dsStore.matchesSearch(".ds_store"))
        XCTAssertFalse(dsStore.matchesSearch("/PHOTO ALBUM/"))
        state.setSelected([sidecar], to: true)
        model.prepareCleanup(for: disk.id, visibleFiles: state.files.filter { $0.matchesSearch(".DS_Store") })
        let request = try XCTUnwrap(model.pendingCleanup)
        XCTAssertEqual(request.boundary.root, disk.volume.url)
        XCTAssertEqual(request.hiddenSelection, [sidecar.id])
        XCTAssertEqual(Set(request.files.map(\.id)), [sidecar.id, dsStore.id])
        XCTAssertEqual(request.selection, FileTally(count: 2, bytes: 45))
        XCTAssertEqual(request.statistics.dsStore, FileTally(count: 1, bytes: 3))
        XCTAssertEqual(request.statistics.appleDouble, FileTally(count: 1, bytes: 42))
    }

    @MainActor
    func testPausedSelectionSurvivesStopAndCompletion() throws {
        try withFixture { root in
            let boundary = try fixtureBoundary(root)
            try appleDoubleFixture.write(to: root.appending(path: "._photo"))
            try Data([1]).write(to: root.appending(path: ".DS_Store"))
            var files: [CleanableFile] = []
            let summary = try ScannerService.scan(boundary: boundary, options: ScanOptions()) { files += $0.files }
            let photo = try XCTUnwrap(files.first { $0.kind == .appleDouble })
            let state = DiskScanState()

            for shouldResume in [false, true] {
                state.begin()
                state.retainPaused(summary, boundary: boundary, files: [photo])
                state.setSelected([photo], to: true)
                XCTAssertTrue(state.changedSelectionWhilePaused)
                if shouldResume {
                    state.phase = .scanning
                    state.finish(summary, boundary: boundary, files: files,
                                 selectDSStore: true, selectAppleDouble: false)
                } else {
                    state.retainCancelled(summary, boundary: boundary, files: files)
                }
                XCTAssertEqual(state.selected, [photo.id])
                XCTAssertEqual(state.selection.count, 1)
            }
        }
    }

    @MainActor
    func testPausedCleanupResultsStayRemovedWhenScanContinues() throws {
        try withFixture { root in
            let boundary = try fixtureBoundary(root)
            try appleDoubleFixture.write(to: root.appending(path: "._photo"))
            try Data([1]).write(to: root.appending(path: ".DS_Store"))
            var files: [CleanableFile] = []
            let summary = try ScannerService.scan(boundary: boundary, options: ScanOptions()) { files += $0.files }
            let photo = try XCTUnwrap(files.first { $0.kind == .appleDouble })
            let state = DiskScanState()
            state.retainPaused(summary, boundary: boundary, files: files)
            XCTAssertTrue(state.phase.allowsCleanup(automatic: false))
            XCTAssertFalse(state.phase.allowsCleanup(automatic: true))
            state.setSelected([photo], to: true)
            var result = CleanupResult()
            result.recordMoved(photo)
            state.applyCleanup(result)
            state.phase = .scanning
            state.updateProgress(summary)
            XCTAssertEqual(state.summary.statistics.appleDouble.count, 0)
            state.finish(summary, boundary: boundary, files: files, selectDSStore: true, selectAppleDouble: false)
            XCTAssertEqual(state.files.map(\.name), [".DS_Store"])
            XCTAssertEqual(state.summary.statistics.count, 1)
        }
    }

    @MainActor
    func testPauseResumeAndStopScanThroughViewModel() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try fixtureDisk(named: "Pause", under: root)
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let allowVerification = DispatchSemaphore(value: 0)
        let model = MainViewModel(preferences: PreferencesStore(defaults: defaults),
                                  operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { [disk] }, verifyVolume: {
            guard allowVerification.wait(timeout: .now() + 4) == .success else { throw CancellationError() }
            try $0.verify()
        })
        model.refreshDisks()
        defer { model.stop() }
        for _ in 0..<400 where model.selectedDisk == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedDisk?.id, disk.id)

        for shouldResume in [true, false] {
            model.startScan(disk.id)
            let state = try XCTUnwrap(model.scans[disk.id])
            XCTAssertEqual(state.phase, .scanning)
            model.pauseScan(disk.id)
            allowVerification.signal()
            for _ in 0..<400 where state.phase == .pausing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(state.phase, .paused)
            XCTAssertEqual(state.summary.visited, 0)
            model.prepareCleanup(for: disk.id)
            XCTAssertNil(model.pendingCleanup)

            if shouldResume {
                model.resumeScan(disk.id)
                let completed = try await waitForScan(disk.id, in: model)
                XCTAssertTrue(completed === state)
                XCTAssertEqual(completed.phase, .finished)
                XCTAssertEqual(completed.files.map(\.name), [".DS_Store"])
            } else {
                model.cancelScan(disk.id)
                let stopped = try await waitForScan(disk.id, in: model)
                XCTAssertEqual(stopped.phase, .cancelled)
                XCTAssertEqual(stopped.summary.visited, 0)
            }
        }
    }

    @MainActor
    func testManuallyCleaningCancelledScanMovesOnlySelectedUnchangedFiles() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try fixtureDisk(named: "Cancelled", under: root)
        let sidecar = disk.volume.url.appending(path: "._photo")
        let unselected = disk.volume.url.appending(path: "._other")
        try appleDoubleFixture.write(to: sidecar)
        try appleDoubleFixture.write(to: unselected)
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let model = MainViewModel(preferences: PreferencesStore(defaults: defaults),
                                  operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { [disk] }, verifyVolume: { try $0.verify() },
                                  cleanFiles: Self.moveToFixtureTrash)
        model.refreshDisks(scan: .manual)
        defer { model.stop() }
        let state = try await waitForScan(disk.id, in: model)
        let boundary = try XCTUnwrap(state.boundary)
        let candidates = state.files
        let summary = state.summary
        state.begin()
        state.retainCancelled(summary, boundary: boundary, files: candidates)
        XCTAssertTrue(state.selected.isEmpty)

        state.setSelected(candidates.filter { $0.name != "._other" }, to: true)
        model.preferences.value.cleanup.automatic = true
        model.processAutomaticCleanupQueue()
        XCTAssertNil(model.pendingCleanup)
        XCTAssertNil(model.cleaningDiskID)

        model.prepareCleanup(for: disk.id)
        let request = try XCTUnwrap(model.pendingCleanup)
        XCTAssertEqual(Set(request.files.map(\.name)), [".DS_Store", "._photo"])
        XCTAssertEqual(request.boundary, boundary)
        try Data("changed after scanning".utf8).write(to: sidecar)
        model.confirmCleanup(request)
        try await waitForCleanup(disk.name, in: model)
        XCTAssertEqual(model.cleanupReport?.result.moved.count, 1)
        XCTAssertEqual(model.cleanupReport?.result.skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.volume.url.appending(path: ".DS_Store").path))
        XCTAssertEqual(try Data(contentsOf: sidecar), Data("changed after scanning".utf8))
        XCTAssertEqual(try Data(contentsOf: unselected), appleDoubleFixture)
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertEqual(Set(state.files.map(\.name)), ["._photo", "._other"])
    }

    @MainActor
    func testDeniedVolumeCanBeRetriedAfterPermissionChanges() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try fixtureDisk(named: "Drive", under: root)
        let path = disk.volume.url.path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let model = MainViewModel(preferences: PreferencesStore(defaults: defaults),
                                  operationLog: OperationLogStore(defaults: defaults),
                                  discoverDisks: { [disk] },
                                  verifyVolume: { try $0.verify() })
        model.start(autoScan: true)
        defer { model.stop() }

        let denied = try await waitForScan(disk.id, in: model)
        XCTAssertEqual(denied.phase, .accessDenied)
        XCTAssertTrue(denied.files.isEmpty)
        XCTAssertNil(denied.boundary)
        model.prepareCleanup(for: disk.id)
        XCTAssertNil(model.pendingCleanup)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        model.startScan(disk.id)
        let retried = try await waitForScan(disk.id, in: model)
        XCTAssertEqual(retried.phase, .finished)
        XCTAssertEqual(retried.files.map(\.name), [".DS_Store"])
    }

    @MainActor
    func testActivityLogCanBeClearedFromPersistentStorage() throws {
        let key = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let log = OperationLogStore(defaults: defaults)
        var result = CleanupResult()
        result.moved.add(42)
        result.recoveryFolder = URL(filePath: "/Volumes/Test Drive/.Trashes/501/DotMop-QA", directoryHint: .isDirectory)
        log.cleanup(disk: "Test Drive", result: result)

        let restored = OperationLogStore(defaults: defaults)
        XCTAssertEqual(restored.entries.first?.tally, FileTally(count: 1, bytes: 42))
        XCTAssertEqual(restored.entries.first?.recoveryFolder, result.recoveryFolder)
        restored.clear()
        XCTAssertTrue(OperationLogStore(defaults: defaults).entries.isEmpty)
    }

    private func fixtureDisk(named name: String, under root: URL, isReadOnly: Bool = false) throws -> DiskInfo {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: url.appending(path: ".DS_Store"))
        let volume = try VolumeReference(url: url, persistentID: nil)
        return DiskInfo(volume: volume, name: name, format: "Fixture",
                        totalBytes: nil, availableBytes: nil, isReadOnly: isReadOnly)
    }

    private static func moveToFixtureTrash(_ boundary: VolumeBoundary, _ files: [CleanableFile],
                                           _ onProgress: (CleanupProgress) -> Void) -> CleanupResult {
        CleanupService.run(boundary: boundary, files: files, locateTrash: { root in
            let trash = root.appending(path: ".Trashes/\(getuid())", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            return trash
        }, onProgress: onProgress)
    }

    @MainActor
    private func waitForCleanup(_ name: String, in model: MainViewModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(4)
        while clock.now < deadline {
            if model.operationLog.entries.contains(where: { $0.kind == .cleanup && $0.diskName == name }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Cleanup did not finish for \(name).")
        throw CocoaError(.userCancelled)
    }

    @MainActor
    private func waitForScan(_ id: String, in model: MainViewModel) async throws -> DiskScanState {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(4)
        while clock.now < deadline {
            if let scan = model.scans[id], scan.phase != .ready, !scan.phase.isActive {
                return scan
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The scan did not finish.")
        throw CocoaError(.userCancelled)
    }
}
