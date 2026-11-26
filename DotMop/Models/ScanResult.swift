import Foundation

struct ScanOptions: Codable, Equatable, Sendable {
    var dsStore = true
    var appleDouble = true

    func includes(_ kind: FileKind) -> Bool {
        switch kind {
        case .dsStore: dsStore
        case .appleDouble: appleDouble
        }
    }
}

struct FileIssue: Codable, Identifiable, Sendable {
    var id = UUID()
    let path: String
    let reason: String
}

struct ScanIssues: Sendable {
    private(set) var total = 0
    private(set) var samples: [FileIssue] = []

    mutating func add(path: String, error: any Error) {
        total += 1
        if samples.count < 100 {
            samples.append(FileIssue(path: path, reason: error.localizedDescription))
        }
    }
}

struct ScanSummary: Sendable {
    var visited = 0
    var statistics = ScanStatistics()
    var issues = ScanIssues()
    var incremental = false
}

struct ScanBatch: Sendable {
    let summary: ScanSummary
    let files: [CleanableFile]
}

enum ScanEvent: Sendable {
    case progress(ScanSummary)
    case paused(ScanSummary, VolumeBoundary, [CleanableFile])
    case finished(ScanSummary, VolumeBoundary, [CleanableFile])
    case cancelled(ScanSummary, VolumeBoundary?, [CleanableFile])
    case accessDenied
    case failed(String)
}
