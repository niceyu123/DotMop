import Foundation
import os
import XCTest
@testable import DotMop

final class ScannerTests: XCTestCase {
    func testAppleDoubleWithLargeEntryTableStillValidates() throws {
        try withFixture { root in
            var bytes = Array(appleDoubleFixture.prefix(26))
            bytes[25] = 5
            for id: UInt8 in 2...6 {
                bytes += [0, 0, 0, id, 0, 0, 0, 86 + id - 2, 0, 0, 0, 1]
            }
            bytes += [1, 2, 3, 4, 5]
            let valid = root.appending(path: "._large-table")
            try Data(bytes).write(to: valid)
            bytes[26 + 4 * 12 + 7] = 86
            try Data(bytes).write(to: root.appending(path: "._overlap"))

            let (files, _) = try scan(fixtureBoundary(root))
            XCTAssertEqual(files.map(\.name), ["._large-table"])
        }
    }

    func testExactNamesAndAppleDoubleStructure() throws {
        try withFixture { root in
            try Data([1, 2, 3]).write(to: root.appending(path: ".DS_Store"))
            try Data([1]).write(to: root.appending(path: ".DS_Store.bak"))
            try Data([1]).write(to: root.appending(path: ".DS_Store.txt"))
            try FileManager.default.createDirectory(at: root.appending(path: "directory"), withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: root.appending(path: "directory/.DS_Store"), withIntermediateDirectories: false)
            try Data([42]).write(to: root.appending(path: "photo"))
            try appleDoubleFixture.write(to: root.appending(path: "._photo"))
            try appleDoubleFixture.write(to: root.appending(path: "._orphan"))
            try Data([0, 5, 22, 7]).write(to: root.appending(path: "._magic-only"))
            var malformed = appleDoubleFixture
            malformed[33] = 0
            try malformed.write(to: root.appending(path: "._invalid-offset"))
            try Data("ordinary file".utf8).write(to: root.appending(path: "._ordinary"))

            let boundary = try fixtureBoundary(root)
            let (files, summary) = try scan(boundary)
            XCTAssertEqual(Set(files.map(\.name)), [".DS_Store", "._photo", "._orphan"])
            XCTAssertEqual(files.first { $0.name == "._photo" }?.originalExists, true)
            XCTAssertEqual(files.first { $0.name == "._orphan" }?.originalExists, false)
            XCTAssertEqual(summary.statistics.dsStore.count, 1)
            XCTAssertEqual(summary.statistics.dsStore.bytes, 3)
            XCTAssertEqual(summary.statistics.appleDouble.count, 2)
            XCTAssertEqual(summary.statistics.appleDouble.bytes, 84)
        }
    }

    func testScannerDoesNotFollowSymlinksOrEnterManagedDirectories() throws {
        try withFixture { base in
            let root = base.appending(path: "Authorized")
            let outside = base.appending(path: "Other")
            let system = root.appending(path: ".Spotlight-V100")
            for folder in [root, outside, system] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            try Data([1]).write(to: outside.appending(path: ".DS_Store"))
            try Data([2]).write(to: system.appending(path: ".DS_Store"))
            try FileManager.default.createSymbolicLink(at: root.appending(path: "Link"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: root.appending(path: ".DS_Store"),
                                                      withDestinationURL: outside.appending(path: ".DS_Store"))
            let volume = try VolumeReference(url: base, persistentID: nil)
            let (files, _) = try scan(VolumeBoundary(volume: volume, root: root))
            XCTAssertTrue(files.isEmpty)
        }
    }

    func testScanDetectsDisconnectedVolume() throws {
        try withFixture { base in
            let volume = base.appending(path: "Mounted")
            let removed = base.appending(path: "Removed")
            try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: false)
            try Data([1]).write(to: volume.appending(path: ".DS_Store"))
            let boundary = try fixtureBoundary(volume)
            var didRemove = false
            XCTAssertThrowsError(try ScannerService.scan(boundary: boundary, options: ScanOptions()) { _ in
                guard !didRemove else { return }
                do {
                    try FileManager.default.moveItem(at: volume, to: removed)
                    didRemove = true
                } catch {
                    XCTFail(error.localizedDescription)
                }
            }) { error in
                XCTAssertEqual(error as? SafetyError, .volumeChanged)
            }
            XCTAssertTrue(didRemove)
        }
    }

    func testPermissionErrorDoesNotPreventScanningSibling() throws {
        try withFixture { root in
            let blocked = root.appending(path: "Blocked")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
            try Data([1]).write(to: root.appending(path: ".DS_Store"))
            let (files, summary) = try scan(fixtureBoundary(root))
            XCTAssertEqual(files.map(\.name), [".DS_Store"])
            XCTAssertEqual(summary.issues.total, 1)
            XCTAssertEqual(summary.issues.samples.first?.path, blocked.path)
        }
    }

    func testCancelledScanStopsBeforePublishingCandidates() async throws {
        let directory = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appending(path: ".DS_Store"))
        let boundary = try fixtureBoundary(directory)
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let task = Task.detached {
            for await _ in gate { break }
            return try ScannerService.scan(boundary: boundary, options: ScanOptions()) { batch in
                XCTAssertTrue(batch.files.isEmpty)
            }
        }
        task.cancel()
        continuation.finish()
        do {
            _ = try await task.value
            XCTFail("A cancelled scan returned a result.")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testRescanAndOptionsProduceIndependentStatistics() throws {
        try withFixture { root in
            try Data([1, 2]).write(to: root.appending(path: ".DS_Store"))
            let boundary = try fixtureBoundary(root)
            let (_, first) = try scan(boundary)
            XCTAssertEqual(first.statistics.dsStore.bytes, 2)
            try Data([1, 2, 3]).write(to: root.appending(path: ".DS_Store"))
            try appleDoubleFixture.write(to: root.appending(path: "._new"))
            let (_, second) = try scan(boundary)
            XCTAssertEqual(second.statistics.dsStore.bytes, 3)
            XCTAssertEqual(second.statistics.appleDouble.count, 1)
            let (filtered, third) = try scan(boundary, options: ScanOptions(dsStore: false, appleDouble: true))
            XCTAssertEqual(filtered.map(\.name), ["._new"])
            XCTAssertEqual(third.statistics.dsStore.count, 0)
        }
    }

    func testIncrementalDirectoryListingsMatchFullScanAfterChanges() throws {
        try withFixture { root in
            let stable = root.appending(path: "Stable", directoryHint: .isDirectory)
            let changed = root.appending(path: "Changed", directoryHint: .isDirectory)
            for folder in [stable, changed] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            for index in 0..<250 {
                try Data().write(to: stable.appending(path: "Photo-\(index).jpg"))
            }
            let repaired = stable.appending(path: "._photo")
            try Data(repeating: 0, count: appleDoubleFixture.count).write(to: repaired)
            try Data([1]).write(to: changed.appending(path: ".DS_Store"))
            let boundary = try fixtureBoundary(root)
            var records: [Data: DirectoryScanRecord] = [:]
            let options = ScanOptions()
            _ = try ScannerService.scan(boundary: boundary, options: options,
                                       recordDirectory: { records[$0] = $1 }) { _ in }
            let index = DirectoryScanIndex(volumeID: UUID().uuidString, journalID: "fixture", event: 123,
                                           options: options, date: Date(), directories: records)
            let cache = root.appending(path: "Cache.plist")
            try index.save(to: cache)
            let restored = try XCTUnwrap(DirectoryScanIndex.load(from: cache, volumeID: index.volumeID,
                                                               journalID: index.journalID, options: options))
            XCTAssertNil(DirectoryScanIndex.load(from: cache, volumeID: index.volumeID,
                                                 journalID: "changed", options: options))
            try appleDoubleFixture.write(to: repaired, options: [])
            try FileManager.default.removeItem(at: changed.appending(path: ".DS_Store"))
            try appleDoubleFixture.write(to: changed.appending(path: "._new"))
            var files: [CleanableFile] = []
            let incremental = try ScannerService.scan(boundary: boundary, options: options, reuse: restored,
                                                       canReuse: { $0.first != "Changed" }) { files += $0.files }
            let (fullFiles, full) = try scan(boundary)
            XCTAssertTrue(incremental.incremental)
            XCTAssertLessThan(incremental.visited, full.visited / 10)
            XCTAssertEqual(incremental.statistics, full.statistics)
            XCTAssertEqual(Set(files.map(\.relativePath)), Set(fullFiles.map(\.relativePath)))
            XCTAssertEqual(Set(files.map(\.name)), ["._photo", "._new"])
        }
    }

    func testCancellationPublishesFinalCandidates() async throws {
        let root = try createFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appending(path: ".DS_Store"))
        let boundary = try fixtureBoundary(root)
        let batches = OSAllocatedUnfairLock(initialState: [CleanableFile]())
        let task = Task.detached {
            try ScannerService.scan(boundary: boundary, options: ScanOptions()) { batch in
                batches.withLock { $0 += batch.files }
                if !batch.files.isEmpty { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled scan must not return a complete summary")
        } catch is CancellationError {
            XCTAssertEqual(batches.withLock { $0.map(\.name) }, [".DS_Store"])
        }
    }

    func testResumeKeepsDirectoryCursorAndDoesNotDuplicateResults() throws {
        try withFixture { root in
            for index in 0..<1_026 {
                try appleDoubleFixture.write(to: root.appending(path: "._fixture-\(index)"))
            }
            let boundary = try fixtureBoundary(root)
            let (expected, full) = try scan(boundary)
            let pause = ScanPauseControl()
            var files: [CleanableFile] = []
            var requested = false
            var pausedWithCount = 0
            var movedURL: URL?
            let resumed = try ScannerService.scan(boundary: boundary, options: ScanOptions(), pause: pause,
                                                  onPaused: {
                defer { pause.resume() }
                pausedWithCount = files.count
                if let first = files.first {
                    do {
                        let destination = root.appending(path: "staged")
                        try FileManager.default.moveItem(at: first.url, to: destination)
                        movedURL = first.url
                    } catch {
                        XCTFail(error.localizedDescription)
                    }
                }
            }) { batch in
                files += batch.files
                if !requested, !files.isEmpty, files.count < expected.count {
                    requested = true
                    pause.requestPause()
                }
            }
            XCTAssertGreaterThan(pausedWithCount, 0)
            XCTAssertLessThan(pausedWithCount, expected.count)
            let moved = try XCTUnwrap(movedURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
            XCTAssertEqual(resumed.visited, full.visited)
            XCTAssertEqual(files.count, expected.count)
            XCTAssertEqual(Set(files.map(\.relativePath)), Set(expected.map(\.relativePath)))
        }
    }

    private func scan(_ boundary: VolumeBoundary, options: ScanOptions = ScanOptions()) throws -> ([CleanableFile], ScanSummary) {
        var files: [CleanableFile] = []
        let summary = try ScannerService.scan(boundary: boundary, options: options) { files += $0.files }
        return (files, summary)
    }
}
