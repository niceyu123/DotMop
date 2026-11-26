import Darwin
import Foundation
import XCTest
@testable import DotMop

final class CleanupTests: XCTestCase {
    func testCancellationFinalizesStagedFilesWithoutCreatingPerFileIssues() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<8 {
            try appleDoubleFixture.write(to: root.appending(path: "._fixture-\(index)"))
        }
        let (boundary, files) = try candidates(in: root)
        let trash = try recoveryTrash(under: root)
        let result = await Task.detached {
            CleanupService.run(boundary: boundary, files: files, trashFolder: { folder in
                let destination = trash.appending(path: folder.lastPathComponent)
                try FileManager.default.moveItem(at: folder, to: destination)
                return destination
            }, onProgress: { progress in
                if progress.processed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }.value

        XCTAssertEqual(result.moved.count, 1)
        XCTAssertEqual(result.unprocessed, 7)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(files.filter { FileManager.default.fileExists(atPath: $0.url.path) }.count, 7)
    }

    func testPermanentDeletionRemovesOnlySelectedUnchangedFiles() throws {
        try withFixture { root in
            let original = root.appending(path: "photo")
            let selected = root.appending(path: "._photo")
            let changed = root.appending(path: "._changed")
            let link = root.appending(path: "._link")
            let unselected = root.appending(path: ".DS_Store")
            try Data([9]).write(to: original)
            for file in [selected, changed, link, unselected] { try appleDoubleFixture.write(to: file) }
            let (boundary, files) = try candidates(in: root)
            try Data([7]).write(to: changed)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)

            let result = CleanupService.run(boundary: boundary, files: files.filter { $0.url != unselected },
                                            method: .permanentDelete, locateTrash: neverTrash, trashFolder: neverTrash)

            XCTAssertEqual(result.deleted, FileTally(count: 1, bytes: 42))
            XCTAssertEqual(result.moved.count, 0)
            XCTAssertEqual(result.skipped, 2)
            XCTAssertNil(result.recoveryFolder)
            XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
            XCTAssertEqual(try Data(contentsOf: original), Data([9]))
            XCTAssertEqual(try Data(contentsOf: changed), Data([7]))
            XCTAssertEqual(try Data(contentsOf: unselected), appleDoubleFixture)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), original.path)
        }
    }

    func testLargeCleanupKeepsRecoveryPathsAcrossSubfolders() throws {
        try withFixture { root in
            for index in 0..<513 {
                try appleDoubleFixture.write(to: root.appending(path: "._fixture-\(index)"))
            }
            let (boundary, files) = try candidates(in: root)
            let trash = try recoveryTrash(under: root)
            let result = CleanupService.run(boundary: boundary, files: files, locateTrash: { _ in trash })

            XCTAssertEqual(result.moved.count, 513)
            XCTAssertTrue(result.issues.isEmpty)
            let recovery = try XCTUnwrap(result.recoveryFolder)
            let first = try FileManager.default.contentsOfDirectory(atPath: recovery.appending(path: "Batch-1").path)
            let second = try FileManager.default.contentsOfDirectory(atPath: recovery.appending(path: "Batch-2").path)
            XCTAssertEqual(first.count, 512)
            XCTAssertEqual(second.count, 1)
            for file in files {
                XCTAssertEqual(try Data(contentsOf: savedFile(file.name, in: result)), appleDoubleFixture)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
            }
        }
    }

    func testSystemTrashReceivesRecoveryFolderWithBothFileKinds() throws {
        try withFixture { root in
            let original = root.appending(path: "photo.jpg")
            try Data([9]).write(to: original)
            try Data([1]).write(to: root.appending(path: ".DS_Store"))
            try appleDoubleFixture.write(to: root.appending(path: "._photo.jpg"))
            let (boundary, files) = try candidates(in: root)
            let trash = try recoveryTrash(under: root)

            let result = CleanupService.run(boundary: boundary, files: files, trashFolder: { folder in
                XCTAssertEqual(folder.deletingLastPathComponent().path, root.path)
                let destination = trash.appending(path: "renamed-recovery")
                try FileManager.default.moveItem(at: folder, to: destination)
                return destination
            })

            XCTAssertEqual(result.moved.count, 2)
            XCTAssertTrue(result.issues.isEmpty)
            XCTAssertEqual(result.recoveryFolder?.lastPathComponent, "renamed-recovery")
            XCTAssertEqual(try Data(contentsOf: savedFile(".DS_Store", in: result)), Data([1]))
            XCTAssertEqual(try Data(contentsOf: savedFile("._photo.jpg", in: result)), appleDoubleFixture)
            XCTAssertEqual(try Data(contentsOf: original), Data([9]))
        }
    }

    func testSystemTrashDenialReportsFilesInRecoveryFolder() throws {
        try withFixture { root in
            let file = root.appending(path: ".DS_Store")
            try Data([7]).write(to: file)
            let (boundary, files) = try candidates(in: root)

            let result = CleanupService.run(boundary: boundary, files: files, trashFolder: { _ in
                throw POSIXError(.EPERM)
            })

            XCTAssertEqual(result.moved.count, 0)
            XCTAssertEqual(result.failed, 0)
            XCTAssertEqual(result.removedFromResults, Set(files.map(\.id)))
            XCTAssertTrue(result.issues.isEmpty)
            XCTAssertEqual(result.retainedRecovery?.tally, FileTally(count: 1, bytes: 1))
            XCTAssertEqual(result.retainedRecovery?.location(on: [boundary.volume])?.url, result.recoveryFolder)
            let folder = try XCTUnwrap(result.recoveryFolder)
            let instructions = try String(contentsOf: folder.appending(path: "Restore.txt"), encoding: .utf8)
            XCTAssertTrue(instructions.contains("Scan folder relative to the volume: ."))
            XCTAssertEqual(try Data(contentsOf: savedFile(".DS_Store", in: result)), Data([7]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testCleanupMovesOnlyCandidatesAndLeavesOriginalIntact() throws {
        try withFixture { base in
            let root = try directory("Scan", under: base)
            let original = root.appending(path: "photo.jpg")
            try Data([10, 11, 12]).write(to: original)
            try Data([1, 2]).write(to: root.appending(path: ".DS_Store"))
            try appleDoubleFixture.write(to: root.appending(path: "._photo.jpg"))
            try Data([1]).write(to: root.appending(path: ".DS_Store.bak"))
            let (boundary, files) = try candidates(in: root)
            let systemTrash = try recoveryTrash(under: root)

            let result = CleanupService.run(boundary: boundary, files: files, locateTrash: { _ in systemTrash })

            XCTAssertEqual(result.moved.count, 2)
            XCTAssertEqual(result.moved.bytes, 44)
            XCTAssertTrue(result.issues.isEmpty)
            XCTAssertEqual(try Data(contentsOf: original), Data([10, 11, 12]))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: ".DS_Store.bak").path))
            XCTAssertEqual(try Data(contentsOf: savedFile(".DS_Store", in: result)), Data([1, 2]))
            XCTAssertEqual(try Data(contentsOf: savedFile("._photo.jpg", in: result)), appleDoubleFixture)
            XCTAssertThrowsError(try NodeMetadata.at(root.appending(path: "._photo.jpg")))
        }
    }

    @MainActor
    func testReplacementAndInPlaceChangeRequireRescan() throws {
        try withFixture { root in
            let folder = try directory("Child", under: root)
            let replaced = root.appending(path: ".DS_Store")
            let changed = folder.appending(path: ".DS_Store")
            try Data([1]).write(to: replaced)
            try Data([2]).write(to: changed)
            let boundary = try fixtureBoundary(root)
            let state = try scanState(boundary)
            try FileManager.default.moveItem(at: replaced, to: root.appending(path: "old"))
            try Data([1]).write(to: replaced)
            try Data([2, 3]).write(to: changed)

            let result = CleanupService.run(boundary: boundary, files: state.files, locateTrash: neverTrash)
            XCTAssertEqual(result.skipped, 2)
            XCTAssertEqual(result.moved.count, 0)
            XCTAssertTrue(result.removedFromResults.isEmpty)
            state.applyCleanup(result)
            XCTAssertEqual(state.files.count, 2)
            XCTAssertEqual(state.summary.statistics.dsStore.count, 2)
            XCTAssertTrue(state.files.allSatisfy { state.cleanupIssues[$0.id]?.disposition == .rescan })
            state.setSelected(state.files, to: true)
            XCTAssertTrue(state.selected.isEmpty)
            XCTAssertEqual(state.selection, FileTally())
            XCTAssertEqual(try Data(contentsOf: replaced), Data([1]))
            XCTAssertEqual(try Data(contentsOf: changed), Data([2, 3]))
            state.begin()
            XCTAssertTrue(state.cleanupIssues.isEmpty)
        }
    }

    @MainActor
    func testMissingLeafIsRemovedButTrashFailureRemainsRetryable() throws {
        try withFixture { root in
            let missing = root.appending(path: ".DS_Store")
            let folder = try directory("Child", under: root)
            let retained = folder.appending(path: ".DS_Store")
            try Data([1]).write(to: missing)
            try Data([2, 3]).write(to: retained)
            let boundary = try fixtureBoundary(root)
            let state = try scanState(boundary)
            try FileManager.default.removeItem(at: missing)
            let result = CleanupService.run(boundary: boundary, files: state.files, locateTrash: { _ in
                throw POSIXError(.EPERM)
            })
            XCTAssertEqual(result.moved.count, 0)
            XCTAssertEqual(result.failed, 1)
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(result.issues.first { $0.disposition == .missing }?.file.path, missing.path)

            state.applyCleanup(result)
            let file = try XCTUnwrap(state.files.first)
            XCTAssertEqual(state.files.map { $0.url.path }, [retained.path])
            XCTAssertEqual(state.summary.statistics.dsStore, FileTally(count: 1, bytes: 2))
            XCTAssertEqual(state.cleanupIssues.count, 1)
            XCTAssertEqual(state.cleanupIssues[file.id]?.outcome, .failed)
            XCTAssertTrue(state.canSelect(file))
        }
    }

    func testSymlinkedParentCannotRedirectCleanupOutsideScope() throws {
        try withFixture { base in
            let root = try directory("Scan", under: base)
            let parent = try directory("Child", under: root)
            let outside = base.appending(path: "Outside")
            try Data([42]).write(to: parent.appending(path: ".DS_Store"))
            let (boundary, files) = try candidates(in: root)
            try FileManager.default.moveItem(at: parent, to: outside)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)

            let result = CleanupService.run(boundary: boundary, files: files, locateTrash: neverTrash)
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(try Data(contentsOf: outside.appending(path: ".DS_Store")), Data([42]))
        }
    }

    func testReplacedLeafSymlinkIsSkipped() throws {
        try withFixture { root in
            let file = root.appending(path: ".DS_Store")
            try Data([6]).write(to: file)
            let (boundary, files) = try candidates(in: root)
            let original = root.appending(path: "normal")
            try FileManager.default.moveItem(at: file, to: original)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)

            let result = CleanupService.run(boundary: boundary, files: files, locateTrash: neverTrash)
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(try Data(contentsOf: original), Data([6]))
        }
    }

    func testReplacedRootIsSkippedEvenWithSameFileAtSamePath() throws {
        try withFixture { base in
            let root = try directory("Scan", under: base)
            let file = root.appending(path: ".DS_Store")
            try Data([2]).write(to: file)
            let boundary = try VolumeBoundary(volume: VolumeReference(url: base, persistentID: nil), root: root)
            var files: [CleanableFile] = []
            _ = try ScannerService.scan(boundary: boundary, options: ScanOptions()) { files += $0.files }

            let old = base.appending(path: "Old")
            try FileManager.default.moveItem(at: root, to: old)
            _ = try directory("Scan", under: base)
            try FileManager.default.moveItem(at: old.appending(path: ".DS_Store"), to: file)

            let result = CleanupService.run(boundary: boundary, files: files, locateTrash: neverTrash)
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(try Data(contentsOf: file), Data([2]))
        }
    }

    func testCleanupChecksAppleDoubleFormatAtOperationTime() throws {
        try withFixture { root in
            let url = root.appending(path: "._counterfeit")
            try Data([0, 5, 22, 7]).write(to: url)
            let boundary = try fixtureBoundary(root)
            let candidate = CleanableFile(url: url, relativePath: ["._counterfeit"], kind: .appleDouble,
                                          metadata: try NodeMetadata.at(url), parent: boundary.rootID, originalExists: false)
            let result = CleanupService.run(boundary: boundary, files: [candidate], locateTrash: neverTrash)
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(result.issues.first?.file.reason, SafetyError.invalidAppleDouble.localizedDescription)
        }
    }

    func testTrashFailureLeavesSourceInPlace() throws {
        try withFixture { root in
            let url = root.appending(path: ".DS_Store")
            try Data([9]).write(to: url)
            let (boundary, files) = try candidates(in: root)
            let result = CleanupService.run(boundary: boundary, files: files, locateTrash: { _ in
                throw POSIXError(.EPERM)
            })
            XCTAssertEqual(result.failed, 1)
            XCTAssertEqual(result.skipped, 0)
            XCTAssertEqual(result.moved.count, 0)
            XCTAssertEqual(try Data(contentsOf: url), Data([9]))
        }
    }

    @MainActor
    func testUnselectedCompanionPreventsImplicitMove() throws {
        try withFixture { root in
            let url = root.appending(path: ".DS_Store")
            let companion = root.appending(path: "._.DS_Store")
            try Data([6]).write(to: url)
            try appleDoubleFixture.write(to: companion)
            let boundary = try fixtureBoundary(root)
            let state = try scanState(boundary)
            let dsStore = try XCTUnwrap(state.files.first { $0.kind == .dsStore })

            let result = CleanupService.run(boundary: boundary, files: [dsStore], locateTrash: neverTrash)
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(result.moved.count, 0)
            XCTAssertTrue(result.removedFromResults.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), Data([6]))
            XCTAssertEqual(try Data(contentsOf: companion), appleDoubleFixture)
            state.applyCleanup(result)
            XCTAssertEqual(state.files.count, 2)
            XCTAssertEqual(state.summary.statistics.dsStore, FileTally(count: 1, bytes: 1))
            XCTAssertEqual(state.cleanupIssues[dsStore.id]?.file.reason, SafetyError.companionPresent.localizedDescription)
            state.setSelected(state.files, to: true)
            XCTAssertEqual(state.selection, FileTally(count: 2, bytes: 43))

            let systemTrash = try recoveryTrash(under: root)
            let retry = CleanupService.run(boundary: boundary, files: state.files.filter { state.selected.contains($0.id) },
                                           locateTrash: { _ in systemTrash })
            state.applyCleanup(retry)
            XCTAssertEqual(retry.moved.count, 2)
            XCTAssertTrue(state.files.isEmpty)
            XCTAssertEqual(state.summary.statistics, ScanStatistics())
            XCTAssertTrue(state.cleanupIssues.isEmpty)
        }
    }

    func testNonCandidateCompanionPreventsImplicitMove() throws {
        try withFixture { root in
            let url = root.appending(path: ".DS_Store")
            let companion = root.appending(path: "._.DS_Store")
            try Data([6]).write(to: url)
            let (boundary, files) = try candidates(in: root)
            let contents = Data("normal file".utf8)
            try contents.write(to: companion)

            let result = CleanupService.run(boundary: boundary, files: files, locateTrash: neverTrash)
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(try Data(contentsOf: companion), contents)
        }
    }

    func testSelectedCompanionIsMovedAsAnIndependentCandidate() throws {
        try withFixture { base in
            let root = try directory("Scan", under: base)
            try Data([3]).write(to: root.appending(path: ".DS_Store"))
            try appleDoubleFixture.write(to: root.appending(path: "._.DS_Store"))
            let (boundary, files) = try candidates(in: root)
            let selected = files.sorted { $0.kind == .dsStore && $1.kind != .dsStore }

            let systemTrash = try recoveryTrash(under: root)
            let result = CleanupService.run(boundary: boundary, files: selected, locateTrash: { _ in systemTrash })

            XCTAssertEqual(result.moved.count, 2)
            XCTAssertEqual(try Data(contentsOf: savedFile("._.DS_Store", in: result)), appleDoubleFixture)
            XCTAssertEqual(try Data(contentsOf: savedFile(".DS_Store", in: result)), Data([3]))
        }
    }

    func testAppleDoubleMovePreservesUnselectedIndexAndRejectsTrashOutsideVolume() throws {
        try withFixture { base in
            let volumeRoot = try directory("Drive", under: base)
            let scope = try directory("Photos", under: volumeRoot)
            let folder = try directory("Album", under: scope)
            let index = folder.appending(path: ".DS_Store")
            let indexSidecar = folder.appending(path: "._.DS_Store")
            let photo = folder.appending(path: "photo.jpg")
            let photoSidecar = folder.appending(path: "._photo.jpg")
            try Data([1]).write(to: index)
            try appleDoubleFixture.write(to: indexSidecar)
            try Data([2]).write(to: photo)
            try appleDoubleFixture.write(to: photoSidecar)
            let boundary = try VolumeBoundary(volume: VolumeReference(url: volumeRoot, persistentID: nil), root: scope)
            var files: [CleanableFile] = []
            _ = try ScannerService.scan(boundary: boundary, options: ScanOptions()) { files += $0.files }
            let selected = files.filter { $0.name == "._photo.jpg" }
            XCTAssertEqual(selected.count, 1)

            let outsideTrash = try recoveryTrash(under: base)
            let failed = CleanupService.run(boundary: boundary, files: selected, locateTrash: { _ in outsideTrash })
            XCTAssertEqual(failed.failed, 1)
            XCTAssertEqual(failed.issues.first?.outcome, .failed)
            XCTAssertTrue(failed.removedFromResults.isEmpty)
            XCTAssertEqual(try Data(contentsOf: photoSidecar), appleDoubleFixture)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outsideTrash.path).isEmpty)

            let systemTrash = try recoveryTrash(under: volumeRoot)
            let result = CleanupService.run(boundary: boundary, files: selected, locateTrash: { _ in systemTrash })
            XCTAssertEqual(result.moved, FileTally(count: 1, bytes: 42))
            XCTAssertFalse(FileManager.default.fileExists(atPath: photoSidecar.path))
            XCTAssertEqual(try Data(contentsOf: savedFile("Album/._photo.jpg", in: result)), appleDoubleFixture)
            XCTAssertEqual(try Data(contentsOf: index), Data([1]))
            XCTAssertEqual(try Data(contentsOf: indexSidecar), appleDoubleFixture)
            XCTAssertEqual(try Data(contentsOf: photo), Data([2]))
        }
    }

    func testReadOnlyParentLeavesSourceInPlace() throws {
        try withFixture { root in
            let folder = try directory("Read Only", under: root)
            let url = folder.appending(path: ".DS_Store")
            try Data([3]).write(to: url)
            let (boundary, files) = try candidates(in: root)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            let result = CleanupService.run(boundary: boundary, files: files, locateTrash: neverTrash)
            XCTAssertEqual(result.failed, 1)
            XCTAssertEqual(try Data(contentsOf: url), Data([3]))
        }
    }

    private func directory(_ name: String, under url: URL) throws -> URL {
        let folder = url.appending(component: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func recoveryTrash(under root: URL) throws -> URL {
        try directory(String(getuid()), under: directory(".Trashes", under: root))
    }

    private func savedFile(_ path: String, in result: CleanupResult) throws -> URL {
        struct Entry: Decodable {
            let file: String
            let path: String
        }
        let folder = try XCTUnwrap(result.recoveryFolder)
        let lines = try Data(contentsOf: folder.appending(path: "Paths.jsonl")).split(separator: 0x0a)
        let entries = try lines.map { try JSONDecoder().decode(Entry.self, from: Data($0)) }
        let name = try XCTUnwrap(entries.first { $0.path == path }?.file)
        return folder.appending(component: name)
    }

    private func candidates(in root: URL) throws -> (VolumeBoundary, [CleanableFile]) {
        let boundary = try fixtureBoundary(root)
        var files: [CleanableFile] = []
        _ = try ScannerService.scan(boundary: boundary, options: ScanOptions()) { files += $0.files }
        return (boundary, files)
    }

    @MainActor
    private func scanState(_ boundary: VolumeBoundary) throws -> DiskScanState {
        let state = DiskScanState()
        state.begin()
        state.summary = try ScannerService.scan(boundary: boundary, options: ScanOptions()) { batch in
            state.consume(batch, selectDSStore: true, selectAppleDouble: false)
        }
        state.phase = .finished
        return state
    }

    private func neverTrash(_ url: URL) throws -> URL {
        XCTFail("Trash must not be called for \(url.lastPathComponent).")
        throw POSIXError(.EPERM)
    }
}
