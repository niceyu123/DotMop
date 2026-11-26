import Foundation

struct RetainedRecovery: Codable, Sendable {
    let tally: FileTally
    let volumeID: String?
    let mountID: String
    let relativeFolder: [String]

    func location(on volumes: [VolumeReference]) -> (volume: VolumeReference, url: URL)? {
        guard !relativeFolder.isEmpty, relativeFolder.allSatisfy(ScopePath.isComponent) else { return nil }
        let matching = volumes.filter { volume in
            if let volumeID { return volume.persistentID == volumeID }
            return volume.id == mountID
        }
        // A duplicated volume UUID can occur when a drive was cloned.
        guard let volume = matching.first(where: { $0.id == mountID })
                ?? (matching.count == 1 ? matching.first : nil) else { return nil }
        let url = relativeFolder.reduce(volume.url) { $0.appending(component: $1, directoryHint: .isDirectory) }
        return (volume, url)
    }
}

enum CleanupMethod: String, Codable, Sendable {
    case trash, permanentDelete
}

struct CleanupProgress: Sendable {
    let processed: Int
    let total: Int
    var isSubmittingToTrash = false
}

struct CleanupRequest: Identifiable, Sendable {
    let id = UUID()
    let diskID: String
    let diskName: String
    let boundary: VolumeBoundary
    let files: [CleanableFile]
    let hiddenSelection: Set<UUID>
    let statistics: ScanStatistics
    let automatic: Bool
    let method: CleanupMethod

    var selection: FileTally {
        FileTally(count: statistics.count, bytes: statistics.dsStore.bytes + statistics.appleDouble.bytes)
    }

    init(diskID: String, diskName: String, boundary: VolumeBoundary,
         files: [CleanableFile], hiddenSelection: Set<UUID>, automatic: Bool = false, method: CleanupMethod = .trash) {
        self.diskID = diskID
        self.diskName = diskName
        self.boundary = boundary
        self.files = files
        self.hiddenSelection = hiddenSelection
        self.automatic = automatic
        self.method = automatic ? .trash : method
        statistics = files.reduce(into: ScanStatistics()) { $0.add($1) }
    }
}

struct CleanupIssue: Identifiable, Sendable {
    enum Outcome: Sendable {
        case failed, skipped
    }

    enum Disposition: Sendable {
        case retry, rescan, missing
    }

    let id: UUID
    let file: FileIssue
    let outcome: Outcome
    let disposition: Disposition
}

struct CleanupResult: Sendable {
    var moved = FileTally()
    var deleted = FileTally()
    var failed = 0
    var skipped = 0
    var unprocessed = 0
    var issues: [CleanupIssue] = []
    var recoveryFolder: URL?
    var retainedRecovery: RetainedRecovery?
    private(set) var removedFromResults: Set<UUID> = []

    mutating func recordMoved(_ candidate: CleanableFile) {
        moved.add(candidate.bytes)
        removedFromResults.insert(candidate.id)
    }

    mutating func recordDeleted(_ candidate: CleanableFile) {
        deleted.add(candidate.bytes)
        removedFromResults.insert(candidate.id)
    }

    mutating func recordRetained(_ files: [CleanableFile], at folder: URL, on volume: VolumeReference) {
        recoveryFolder = folder
        var tally = FileTally()
        for file in files {
            tally.add(file.bytes)
            removedFromResults.insert(file.id)
        }
        retainedRecovery = RetainedRecovery(tally: tally, volumeID: volume.persistentID, mountID: volume.id,
                                            relativeFolder: ScopePath.relative(folder, under: volume.url) ?? [])
    }

    mutating func record(_ candidate: CleanableFile, outcome: CleanupIssue.Outcome, reason: String,
                         disposition: CleanupIssue.Disposition = .retry) {
        switch outcome {
        case .failed: failed += 1
        case .skipped: skipped += 1
        }
        if disposition == .missing { removedFromResults.insert(candidate.id) }
        issues.append(CleanupIssue(
            id: candidate.id,
            file: FileIssue(path: candidate.url.path(percentEncoded: false), reason: reason),
            outcome: outcome,
            disposition: disposition
        ))
    }

    static func skipped(_ request: CleanupRequest, reason: String,
                        disposition: CleanupIssue.Disposition = .retry) -> Self {
        var result = Self()
        for file in request.files {
            result.record(file, outcome: .skipped, reason: reason, disposition: disposition)
        }
        return result
    }
}

struct CleanupReport: Identifiable, Sendable {
    let id = UUID()
    let diskName: String
    let result: CleanupResult
    var method: CleanupMethod = .trash
}
