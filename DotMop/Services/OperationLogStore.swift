import Foundation
import Observation

struct OperationLogEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case scan, cleanup
    }

    var id = UUID()
    var date = Date()
    let diskName: String
    let kind: Kind
    let tally: FileTally
    var failed = 0
    var skipped = 0
    let issueCount: Int
    let issues: [FileIssue]
    var recoveryFolder: URL?
    var retainedRecovery: RetainedRecovery?
    var recoveryNoticeDismissed: Bool?
    var unprocessed: Int?
    var automatic: Bool?
    var method: CleanupMethod?

    var hasPendingRecovery: Bool { retainedRecovery != nil && recoveryNoticeDismissed != true }
}

@Observable
@MainActor
final class OperationLogStore {
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "operationLog.v1"
    private(set) var entries: [OperationLogEntry]

    var pendingRecovery: OperationLogEntry? {
        entries.first(where: \.hasPendingRecovery)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([OperationLogEntry].self, from: $0) } ?? []
    }

    func scan(disk: String, summary: ScanSummary) {
        let tally = FileTally(count: summary.statistics.count,
                              bytes: summary.statistics.dsStore.bytes + summary.statistics.appleDouble.bytes)
        append(OperationLogEntry(diskName: disk, kind: .scan, tally: tally, issueCount: summary.issues.total,
                                 issues: Array(summary.issues.samples.prefix(40))))
    }

    func cleanup(disk: String, result: CleanupResult, automatic: Bool = false, method: CleanupMethod = .trash) {
        let tally = method == .permanentDelete ? result.deleted : result.moved
        append(OperationLogEntry(diskName: disk, kind: .cleanup, tally: tally, failed: result.failed,
                                 skipped: result.skipped, issueCount: result.issues.count,
                                 issues: result.issues.prefix(40).map(\.file), recoveryFolder: result.recoveryFolder,
                                 retainedRecovery: result.retainedRecovery,
                                 unprocessed: result.unprocessed == 0 ? nil : result.unprocessed,
                                 automatic: automatic, method: method == .trash ? nil : method))
    }

    func dismissRecoveryNotice(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.retainedRecovery != nil }) else { return }
        entries[index].recoveryNoticeDismissed = true
        save()
    }

    func clear() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.key)
    }

    private func append(_ entry: OperationLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 30 {
            entries.remove(at: entries.lastIndex { !$0.hasPendingRecovery } ?? entries.count - 1)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}
