import Foundation
import Observation

enum ScanPhase: Equatable {
    case ready, scanning, pausing, paused, cancelling, cancelled, finished, accessDenied, failed(String)

    var isActive: Bool { self == .scanning || self == .pausing || self == .cancelling }
    var hasResults: Bool { self == .finished || self == .paused || self == .cancelled }

    func allowsCleanup(automatic: Bool) -> Bool {
        self == .finished || (!automatic && (self == .paused || self == .cancelled))
    }
}

@Observable
@MainActor
final class DiskScanState {
    var phase: ScanPhase = .ready
    private(set) var files: [CleanableFile] = [] {
        didSet { filesRevision = UUID() }
    }
    private(set) var filesRevision = UUID()
    var summary = ScanSummary()
    var boundary: VolumeBoundary?
    private(set) var selected: Set<UUID> = []
    private(set) var changedSelectionWhilePaused = false
    private(set) var selection = FileTally()
    private(set) var cleanupIssues: [UUID: CleanupIssue] = [:]
    @ObservationIgnored private var removedWhilePaused: Set<UUID> = []
    @ObservationIgnored private var removedStatistics = ScanStatistics()

    func begin() {
        phase = .scanning
        files.removeAll()
        summary = ScanSummary()
        boundary = nil
        cleanupIssues.removeAll()
        changedSelectionWhilePaused = false
        removedWhilePaused.removeAll()
        removedStatistics = ScanStatistics()
        resetSelection()
    }

    func consume(_ batch: ScanBatch, selectDSStore: Bool, selectAppleDouble: Bool) {
        summary = batch.summary
        guard !batch.files.isEmpty else { return }
        files.append(contentsOf: batch.files)
        setSelected(batch.files.filter { file in
            file.kind == .dsStore ? selectDSStore : selectAppleDouble
        }, to: true)
    }

    func finish(_ summary: ScanSummary, boundary: VolumeBoundary, files: [CleanableFile],
                selectDSStore: Bool, selectAppleDouble: Bool) {
        retainResults(summary, boundary: boundary, files: files)
        if !changedSelectionWhilePaused {
            setSelected(self.files.filter { $0.kind == .dsStore ? selectDSStore : selectAppleDouble }, to: true)
        }
        phase = .finished
    }

    func retainCancelled(_ summary: ScanSummary, boundary: VolumeBoundary?, files: [CleanableFile]) {
        retainResults(summary, boundary: boundary, files: files)
        phase = .cancelled
    }

    func retainPaused(_ summary: ScanSummary, boundary: VolumeBoundary, files: [CleanableFile]) {
        retainResults(summary, boundary: boundary, files: files)
        phase = .paused
    }

    func updateProgress(_ progress: ScanSummary) {
        var progress = progress
        progress.statistics.dsStore.count -= removedStatistics.dsStore.count
        progress.statistics.dsStore.bytes -= removedStatistics.dsStore.bytes
        progress.statistics.appleDouble.count -= removedStatistics.appleDouble.count
        progress.statistics.appleDouble.bytes -= removedStatistics.appleDouble.bytes
        summary = progress
    }

    private func retainResults(_ progress: ScanSummary, boundary: VolumeBoundary?, files: [CleanableFile]) {
        updateProgress(progress)
        self.boundary = boundary
        self.files = removedWhilePaused.isEmpty ? files : files.filter { !removedWhilePaused.contains($0.id) }
    }

    func discard(phase: ScanPhase) {
        self.phase = phase
        files.removeAll()
        summary = ScanSummary()
        boundary = nil
        cleanupIssues.removeAll()
        resetSelection()
    }

    func canSelect(_ file: CleanableFile) -> Bool {
        cleanupIssues[file.id]?.disposition != .rescan
    }

    func setSelected(_ files: [CleanableFile], to enabled: Bool) {
        var changed = selection
        for file in files {
            if enabled, canSelect(file), selected.insert(file.id).inserted {
                changed.add(file.bytes)
            } else if !enabled, selected.remove(file.id) != nil {
                changed.remove(file.bytes)
            }
        }
        if phase == .paused, selection != changed { changedSelectionWhilePaused = true }
        selection = changed
    }

    func applyCleanup(_ result: CleanupResult) {
        if !result.removedFromResults.isEmpty {
            var updated = summary.statistics
            files.removeAll { file in
                guard result.removedFromResults.contains(file.id) else { return false }
                updated.remove(file)
                if phase == .paused {
                    removedWhilePaused.insert(file.id)
                    removedStatistics.add(file)
                }
                return true
            }
            summary.statistics = updated
        }
        for id in result.removedFromResults { cleanupIssues.removeValue(forKey: id) }
        for issue in result.issues where issue.disposition != .missing {
            cleanupIssues[issue.id] = issue
        }
        selected.subtract(result.removedFromResults)
        selected.subtract(result.issues.lazy.filter { $0.disposition == .rescan }.map(\.id))
        selection = files.reduce(into: FileTally()) { tally, file in
            if selected.contains(file.id) { tally.add(file.bytes) }
        }
    }

    private func resetSelection() {
        selected.removeAll()
        selection = FileTally()
    }
}
