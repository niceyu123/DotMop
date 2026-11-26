import CoreServices
import Darwin
import Foundation

struct DirectoryScanRecord: Codable, Sendable {
    let modified: NodeTimestamp
    let changed: NodeTimestamp
    let created: NodeTimestamp
    let inode: ino_t
    let children: [String]
    let candidates: [String]

    func matches(_ directory: NodeMetadata) -> Bool {
        inode == directory.identity.inode && modified == directory.modified
            && changed == directory.changed && created == directory.created
    }
}

struct DirectoryScanIndex: Codable, Sendable {
    let volumeID: String
    let journalID: String
    let event: UInt64
    let options: ScanOptions
    let date: Date
    var directories: [Data: DirectoryScanRecord]

    private static let maxBytes = 32 * 1_024 * 1_024

    static func cacheURL(volumeID: String) -> URL? {
        guard UUID(uuidString: volumeID) != nil,
              let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return root.appending(path: "com.dotmop.mac/ScanIndex-v1", directoryHint: .isDirectory)
            .appending(component: volumeID.lowercased() + ".plist", directoryHint: .notDirectory)
    }

    static func load(from url: URL, volumeID: String, journalID: String, options: ScanOptions) -> Self? {
        let ageLimit: TimeInterval = 7 * 24 * 60 * 60
        guard let metadata = try? NodeMetadata.at(url), metadata.isRegular, metadata.size <= maxBytes,
              let data = try? Data(contentsOf: url),
              let index = try? PropertyListDecoder().decode(Self.self, from: data),
              index.volumeID == volumeID, index.journalID == journalID, index.options == options,
              Date().timeIntervalSince(index.date) >= 0, Date().timeIntervalSince(index.date) < ageLimit else { return nil }
        return index
    }

    func save(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBytes else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
    }

    static func scan(boundary: VolumeBoundary, options: ScanOptions, useIndex: Bool, allowReuse: Bool,
                     pause: ScanPauseControl? = nil, onPaused: () -> Void = {},
                     onUpdate: (ScanBatch) -> Void) throws -> ScanSummary {
        let device = boundary.volume.node.device
        guard useIndex, ScopePath.same(boundary.root, boundary.volume.url),
              let volumeID = boundary.volume.persistentID, let url = cacheURL(volumeID: volumeID),
              let journal = VolumeChangeHistory.journalID(device: device) else {
            return try ScannerService.scan(boundary: boundary, options: options, pause: pause, onPaused: onPaused,
                                           onUpdate: onUpdate)
        }
        let cached = allowReuse ? load(from: url, volumeID: volumeID, journalID: journal, options: options) : nil
        let replay = cached.flatMap { VolumeChangeHistory.replay(device: device, since: $0.event) }
        let history = replay?.anchorFound == true ? replay : nil
        var event = replay?.latest
        if event == nil {
            let lastKnown = FSEventsGetLastEventIdForDeviceBeforeTime(device, Date().timeIntervalSince1970)
            event = VolumeChangeHistory.replay(device: device, since: max(1, lastKnown))?.latest
        }
        guard let event else {
            return try ScannerService.scan(boundary: boundary, options: options, pause: pause, onPaused: onPaused,
                                           onUpdate: onUpdate)
        }
        // Anchor the snapshot before reading directories so changes during the scan are replayed next time.
        let date = Date()
        var records: [Data: DirectoryScanRecord] = [:]
        var remainingBudget = 12 * 1_024 * 1_024
        let summary = try ScannerService.scan(boundary: boundary, options: options, reuse: history == nil ? nil : cached,
                                              canReuse: { history?.permits($0) == true },
                                              recordDirectory: { path, record in
            guard remainingBudget > 0 else { return }
            let names = record.children.lazy.map { $0.utf8.count + 8 }.reduce(0, +)
                + record.candidates.lazy.map { $0.utf8.count + 8 }.reduce(0, +)
            let cost = path.count + 160 + names
            if cost <= remainingBudget {
                records[path] = record
                remainingBudget -= cost
            }
        }, pause: pause, onPaused: onPaused, onUpdate: onUpdate)
        try Task.checkCancellation()
        if summary.issues.total == 0, !records.isEmpty, VolumeChangeHistory.journalID(device: device) == journal {
            let index = Self(volumeID: volumeID, journalID: journal, event: event, options: options,
                             date: history == nil ? date : cached?.date ?? date, directories: records)
            try? index.save(to: url)
        }
        return summary
    }
}

enum VolumeChangeHistory {
    struct History {
        let latest: UInt64
        let anchorFound: Bool
        let dirty: Set<String>
        let invalidatedSubtrees: Set<String>

        func permits(_ path: [String]) -> Bool {
            guard !dirty.contains(VolumeChangeHistory.comparisonKey(path)) else { return false }
            for count in path.indices where invalidatedSubtrees.contains(VolumeChangeHistory.comparisonKey(path.prefix(count + 1))) {
                return false
            }
            return true
        }
    }

    private final class Replay {
        let since: UInt64
        let done = DispatchSemaphore(value: 0)
        var latest: UInt64 = 0
        var anchorFound = false
        var complete = false
        var unreliable = false
        var dirty: Set<String> = []
        var invalidatedSubtrees: Set<String> = []

        init(since: UInt64) { self.since = since }
    }

    static func journalID(device: dev_t) -> String? {
        FSEventsCopyUUIDForDevice(device).map { CFUUIDCreateString(nil, $0) as String }
    }

    static func replay(device: dev_t, since: UInt64) -> History? {
        let replay = Replay(since: since)
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(replay).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagFullHistory | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, context, count, paths, flags, ids in
            guard let context else { return }
            let replay = Unmanaged<Replay>.fromOpaque(context).takeUnretainedValue()
            guard !replay.complete, !replay.unreliable else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            for index in 0..<count {
                let event = flags[index]
                if event & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    replay.complete = true
                    break
                }
                if event & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                  | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                                  | kFSEventStreamEventFlagRootChanged) != 0 {
                    replay.unreliable = true
                    break
                }
                guard let path = paths[index] as? String else {
                    replay.unreliable = true
                    break
                }
                let id = ids[index]
                if event & UInt32(kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 {
                    // The volume itself mounting is expected. Nested mounts can change the scan boundary.
                    if path.isEmpty || path == "/" { continue }
                    replay.unreliable = true
                    break
                }
                replay.latest = max(replay.latest, id)
                if id == replay.since { replay.anchorFound = true }
                guard replay.since > 1 else { continue }
                // FullHistory may replay the overlapping chunk out of order.
                // The scan covered changes through the saved ID before enumerating directories.
                guard id > replay.since else { continue }
                let parts = path.split(separator: "/").map(String.init)
                guard !parts.isEmpty, parts.allSatisfy(ScopePath.isComponent) else {
                    replay.unreliable = true
                    break
                }
                if parts.dropLast().contains(where: { !ScopePath.allowsDirectory($0) }) { continue }
                replay.dirty.insert(VolumeChangeHistory.comparisonKey(parts.dropLast()))
                if event & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                    || event & UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) == 0 {
                    replay.invalidatedSubtrees.insert(VolumeChangeHistory.comparisonKey(parts))
                }
                if replay.dirty.count + replay.invalidatedSubtrees.count > 16_000 {
                    replay.unreliable = true
                    break
                }
            }
            if replay.complete || replay.unreliable { replay.done.signal() }
        }
        guard let stream = FSEventStreamCreateRelativeToDevice(nil, callback, &context, device, [""] as CFArray,
                                                               since, 0, flags) else { return nil }
        let queue = DispatchQueue(label: "com.dotmop.scan-history")
        FSEventStreamSetDispatchQueue(stream, queue)
        defer {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        guard FSEventStreamStart(stream) else { return nil }
        let completed = replay.done.wait(timeout: .now() + 2) == .success
        FSEventStreamStop(stream)
        // Drain any callback before reading and releasing its context.
        queue.sync {}
        guard completed, replay.complete, !replay.unreliable, replay.latest > 1 else { return nil }
        return History(latest: replay.latest, anchorFound: replay.anchorFound, dirty: replay.dirty,
                       invalidatedSubtrees: replay.invalidatedSubtrees)
    }

    private static func comparisonKey(_ path: some Collection<String>) -> String {
        path.joined(separator: "/").folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
