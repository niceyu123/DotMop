import Darwin
import Foundation

final class ScanPauseControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var pauseRequested = false

    func requestPause() {
        condition.lock()
        pauseRequested = true
        condition.unlock()
    }

    func resume() {
        condition.lock()
        pauseRequested = false
        condition.broadcast()
        condition.unlock()
    }

    func waitIfPaused(onPaused: () -> Void) throws -> Bool {
        condition.lock()
        let shouldPause = pauseRequested
        condition.unlock()
        try Task.checkCancellation()
        guard shouldPause else { return false }
        onPaused()
        condition.lock()
        while pauseRequested { condition.wait() }
        condition.unlock()
        try Task.checkCancellation()
        return true
    }
}

enum ScannerService {
    static func scan(
        boundary: VolumeBoundary,
        options: ScanOptions,
        reuse: DirectoryScanIndex? = nil,
        canReuse: (([String]) -> Bool)? = nil,
        recordDirectory: ((Data, DirectoryScanRecord) -> Void)? = nil,
        pause: ScanPauseControl? = nil,
        onPaused: () -> Void = {},
        onUpdate: (ScanBatch) -> Void
    ) throws -> ScanSummary {
        try Task.checkCancellation()
        let root = try boundary.openRoot()
        let rootPath = boundary.root
        var stack = [try ScanDirectory(file: root, url: rootPath, path: [], metadata: root.metadata())]
        var summary = ScanSummary()
        var pending: [CleanableFile] = []
        let clock = ContinuousClock()
        var nextUpdate = clock.now + .milliseconds(125)
        onUpdate(ScanBatch(summary: summary, files: []))

        while let directory = stack.last {
            if Task.isCancelled {
                onUpdate(ScanBatch(summary: summary, files: pending))
                throw CancellationError()
            }
            do {
                if try pause?.waitIfPaused(onPaused: {
                    // Capture unread entries before the UI can move any files in these directories.
                    for openDirectory in stack { openDirectory.freezeRemainingEntries() }
                    onUpdate(ScanBatch(summary: summary, files: pending))
                    pending.removeAll(keepingCapacity: true)
                    onPaused()
                }) == true {
                    _ = try boundary.openRoot()
                }
            } catch is CancellationError {
                onUpdate(ScanBatch(summary: summary, files: pending))
                throw CancellationError()
            }
            if pending.count >= 1_024 || clock.now >= nextUpdate {
                _ = try boundary.openRoot()
                onUpdate(ScanBatch(summary: summary, files: pending))
                pending.removeAll(keepingCapacity: true)
                nextUpdate = clock.now + .milliseconds(125)
            }

            let entry: ScanDirectory.Entry
            do {
                guard let read = try directory.next() else {
                    let stamp = directory.stamp
                    if let recordDirectory, !directory.path.isEmpty, directory.cacheable {
                        if try directory.metadata() != stamp {
                            summary.issues.add(path: directory.url.path(percentEncoded: false), error: SafetyError.fileChanged)
                        } else {
                            recordDirectory(Data(directory.path.joined(separator: "/").utf8), DirectoryScanRecord(
                                modified: stamp.modified, changed: stamp.changed, created: stamp.created,
                                inode: stamp.identity.inode,
                                children: directory.children, candidates: directory.candidates))
                        }
                    }
                    stack.removeLast()
                    continue
                }
                entry = read
            } catch {
                if directory.path.isEmpty && isFileAccessDenied(error) { throw error }
                let url = try boundary.directoryURL(directory.path)
                summary.issues.add(path: url.path(percentEncoded: false), error: error)
                stack.removeLast()
                continue
            }

            summary.visited += 1
            let kind = FileKind.matching(entry.name).flatMap { options.includes($0) ? $0 : nil }
            let mightBeDirectory = entry.type == DT_DIR || entry.type == DT_UNKNOWN
            guard kind != nil || mightBeDirectory else { continue }
            if mightBeDirectory && !ScopePath.allowsDirectory(entry.name) { continue }
            let components = directory.path + [entry.name]

            do {
                try autoreleasepool {
                    if kind != nil {
                        let current = try URL(filePath: OpenFile.currentPath(of: directory.descriptor))
                        guard ScopePath.same(current, directory.url) else {
                            throw SafetyError.fileChanged
                        }
                    }
                    let metadata = try NodeMetadata.named(entry.name, in: directory.descriptor)
                    guard metadata.identity.device == boundary.volume.node.device else { return }
                    if metadata.isDirectory {
                        let url = directory.url.appending(component: entry.name, directoryHint: .isDirectory)
                        let child = try OpenFile(at: url, directory: true)
                        let childMetadata = try child.metadata()
                        guard childMetadata.identity == metadata.identity,
                              FilesystemIdentity(try child.filesystem()) == boundary.volume.filesystemID,
                              ScopePath.same(try URL(filePath: child.currentPath()), url) else { return }
                        if recordDirectory != nil, !directory.path.isEmpty { directory.children.append(entry.name) }
                        let cached = reuse.flatMap { $0.directories[Data(components.joined(separator: "/").utf8)] }
                        let listing = cached.flatMap { $0.matches(childMetadata) && canReuse?(components) == true ? $0 : nil }
                        if listing != nil { summary.incremental = true }
                        stack.append(try ScanDirectory(file: child, url: url, path: components, metadata: childMetadata,
                                                       listing: listing))
                    } else if let kind, metadata.isRegular {
                        if recordDirectory != nil, !directory.path.isEmpty { directory.candidates.append(entry.name) }
                        let url = directory.url.appending(component: entry.name, directoryHint: .notDirectory)
                        let originalExists: Bool?
                        if kind == .appleDouble {
                            guard metadata.size >= AppleDoubleValidator.headerSize else { return }
                            let file = try OpenFile(name: entry.name, in: directory.descriptor)
                            guard try file.metadata() == metadata else { throw SafetyError.fileChanged }
                            guard try AppleDoubleValidator.isValid(file, size: metadata.size) else { return }
                            guard try file.metadata() == metadata else { throw SafetyError.fileChanged }
                            originalExists = Self.originalExists(for: entry.name, parent: directory.descriptor)
                        } else {
                            originalExists = nil
                        }
                        let candidate = CleanableFile(url: url, relativePath: components, kind: kind, metadata: metadata,
                                                      parent: directory.identity, originalExists: originalExists)
                        pending.append(candidate)
                        summary.statistics.add(candidate)
                    }
                }
            } catch {
                directory.cacheable = false
                let path = directory.url.appending(component: entry.name, directoryHint: .notDirectory).path(percentEncoded: false)
                summary.issues.add(path: path, error: error)
            }
        }

        onUpdate(ScanBatch(summary: summary, files: pending))
        try Task.checkCancellation()
        _ = try boundary.openRoot()
        return summary
    }

    private static func originalExists(for sidecar: String, parent: Int32) -> Bool? {
        let name = String(decoding: sidecar.utf8.dropFirst(2), as: UTF8.self)
        guard ScopePath.isComponent(name) else { return nil }
        do {
            _ = try NodeMetadata.named(name, in: parent)
            return true
        } catch let error as POSIXError where error.code == .ENOENT {
            return false
        } catch {
            return nil
        }
    }
}

private final class ScanDirectory {
    struct Entry {
        let name: String
        let type: Int32
    }

    let path: [String]
    let url: URL
    let identity: NodeIdentity
    let stamp: NodeMetadata
    var cacheable = true
    var children: [String] = []
    var candidates: [String] = []
    private var cachedChildren: Array<String>.Iterator?
    private var cachedCandidates: Array<String>.Iterator?
    private var frozenEntries: Array<Entry>.Iterator?
    private var frozenError: (any Error)?
    private let stream: UnsafeMutablePointer<DIR>
    var descriptor: Int32 { dirfd(stream) }

    init(file: OpenFile, url: URL, path: [String], metadata: NodeMetadata, listing: DirectoryScanRecord? = nil) throws {
        let copy = fcntl(file.descriptor, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw currentPOSIXError() }
        guard let stream = fdopendir(copy) else {
            let error = currentPOSIXError()
            close(copy)
            throw error
        }
        self.stream = stream
        self.path = path
        self.url = url
        identity = metadata.identity
        stamp = metadata
        cachedChildren = listing?.children.makeIterator()
        cachedCandidates = listing?.candidates.makeIterator()
    }

    deinit { closedir(stream) }

    func metadata() throws -> NodeMetadata {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw currentPOSIXError() }
        return NodeMetadata(value)
    }

    func next() throws -> Entry? {
        if frozenEntries != nil {
            if let entry = frozenEntries?.next() { return entry }
            if let frozenError { throw frozenError }
            return nil
        }
        return try nextLiveEntry()
    }

    func freezeRemainingEntries() {
        guard frozenEntries == nil, cachedChildren == nil else { return }
        var entries: [Entry] = []
        do {
            while !Task.isCancelled, let entry = try nextLiveEntry() { entries.append(entry) }
        } catch {
            frozenError = error
        }
        frozenEntries = entries.makeIterator()
    }

    private func nextLiveEntry() throws -> Entry? {
        if cachedChildren != nil {
            if let name = cachedChildren?.next() {
                guard ScopePath.allowsDirectory(name) else { throw SafetyError.unsafePath }
                return Entry(name: name, type: DT_DIR)
            }
            if let name = cachedCandidates?.next() {
                guard ScopePath.isComponent(name), FileKind.matching(name) != nil else { throw SafetyError.unsafePath }
                return Entry(name: name, type: DT_UNKNOWN)
            }
            return nil
        }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw currentPOSIXError() }
                return nil
            }
            let count = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(bytes: bytes.prefix(count), encoding: .utf8)
            }
            guard let name, ScopePath.isComponent(name) else { continue }
            return Entry(name: name, type: Int32(entry.pointee.d_type))
        }
    }
}
