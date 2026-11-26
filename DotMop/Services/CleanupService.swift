import Darwin
import Foundation

enum CleanupService {
    static func run(
        boundary: VolumeBoundary,
        files: [CleanableFile],
        method: CleanupMethod = .trash,
        locateTrash: ((URL) throws -> URL)? = nil,
        trashFolder: (URL) throws -> URL = moveFolderToSystemTrash,
        onProgress: (CleanupProgress) -> Void = { _ in }
    ) -> CleanupResult {
        var result = CleanupResult()
        if Task.isCancelled {
            result.unprocessed = files.count
            return result
        }
        var recoveryFolder: RecoveryFolder?
        var staged: [CleanableFile] = []
        // Each selected sidecar must be handled before the corresponding file.
        let orderedFiles = files.sorted { $0.name.utf8.count > $1.name.utf8.count }
        let clock = ContinuousClock()
        var nextUpdate = clock.now
        for (offset, candidate) in orderedFiles.enumerated() {
            defer {
                if result.unprocessed == 0, clock.now >= nextUpdate {
                    onProgress(CleanupProgress(processed: offset + 1, total: orderedFiles.count))
                    nextUpdate = clock.now + .milliseconds(125)
                }
            }
            let target: ValidatedTarget
            do {
                try Task.checkCancellation()
                target = try validate(candidate, boundary: boundary)
                try Task.checkCancellation()
            } catch is CancellationError {
                result.unprocessed = orderedFiles.count - offset
                break
            } catch {
                let posix = (error as? POSIXError)?.code
                let safetyError = error as? SafetyError
                let accessDenied = isFileAccessDenied(error) || posix == .EROFS || safetyError == .readOnly
                let outcome: CleanupIssue.Outcome = accessDenied ? .failed : .skipped
                let disposition: CleanupIssue.Disposition
                switch safetyError {
                case .fileMissing: disposition = .missing
                case .companionPresent, .readOnly: disposition = .retry
                default: disposition = accessDenied ? .retry : .rescan
                }
                let reason = posix == .ENOENT || posix == .ENOTDIR ? SafetyError.fileChanged.localizedDescription
                    : posix == .ELOOP ? SafetyError.unsafePath.localizedDescription : error.localizedDescription
                result.record(candidate, outcome: outcome, reason: reason, disposition: disposition)
                continue
            }

            do {
                switch method {
                case .permanentDelete:
                    try verifyBeforeMutation(candidate, target: target, boundary: boundary)
                    try Task.checkCancellation()
                    guard unlinkat(target.parent.descriptor, candidate.name, 0) == 0 else {
                        throw currentPOSIXError()
                    }
                    result.recordDeleted(candidate)
                case .trash:
                    let folder = try recoveryFolder ?? RecoveryFolder(boundary: boundary, target: target,
                                                                      files: orderedFiles, locateTrash: locateTrash)
                    recoveryFolder = folder
                    try folder.move(candidate, at: offset, from: target, boundary: boundary)
                    staged.append(candidate)
                }
            } catch is CancellationError {
                result.unprocessed = orderedFiles.count - offset
                break
            } catch {
                let current = try? NodeMetadata.named(candidate.name, in: target.parent.descriptor)
                result.record(candidate, outcome: .failed, reason: error.localizedDescription,
                              disposition: current == candidate.metadata ? .retry : .rescan)
            }
        }
        if let folder = recoveryFolder {
            if staged.isEmpty {
                folder.discardEmpty()
            } else {
                onProgress(CleanupProgress(processed: orderedFiles.count - result.unprocessed, total: orderedFiles.count,
                                           isSubmittingToTrash: true))
                do {
                    result.recoveryFolder = try locateTrash == nil ? folder.sendToTrash(boundary: boundary, using: trashFolder) : folder.url
                    for candidate in staged { result.recordMoved(candidate) }
                } catch {
                    result.recordRetained(staged, at: folder.url, on: boundary.volume)
                }
            }
        }
        return result
    }

    private static func moveFolderToSystemTrash(_ url: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        guard let destination else { throw SafetyError.trashUnavailable }
        return destination as URL
    }

    private struct ValidatedTarget {
        let url: URL
        let root: OpenFile
        let parent: OpenFile
        let file: OpenFile
    }

    private final class RecoveryFolder {
        let url: URL
        let directory: OpenFile
        private let parent: OpenFile
        private let name: String
        private var supportsExclusiveRename = true
        private let usesSubfolders: Bool
        private var activeSubfolder: (name: String, file: OpenFile)?
        private var subfolders: [String] = []

        init(boundary: VolumeBoundary, target: ValidatedTarget, files: [CleanableFile],
             locateTrash: ((URL) throws -> URL)?) throws {
            let volume = boundary.volume
            let parent: OpenFile
            let parentURL: URL
            if let locateTrash {
                parentURL = try locateTrash(volume.url)
                guard ScopePath.relative(parentURL, under: volume.url) == [".Trashes", String(getuid())] else {
                    throw SafetyError.trashUnavailable
                }
                parent = try OpenFile(at: parentURL, directory: true)
                let metadata = try parent.metadata()
                guard metadata.owner == geteuid(), metadata.mode & 0o022 == 0 else {
                    throw SafetyError.trashUnavailable
                }
            } else {
                parent = target.parent
                parentURL = target.url.deletingLastPathComponent()
            }
            guard FilesystemIdentity(try parent.filesystem()) == volume.filesystemID,
                  try matchesPath(parent, parentURL) else { throw SafetyError.trashUnavailable }
            try volume.verify()
            let name = "DotMop-\(UUID().uuidString)"
            guard mkdirat(parent.descriptor, name, 0o700) == 0 else { throw currentPOSIXError() }
            let folder = try OpenFile(directory: name, in: parent)
            let folderURL = parentURL.appending(component: name, directoryHint: .isDirectory)
            guard FilesystemIdentity(try folder.filesystem()) == volume.filesystemID,
                  try matchesPath(folder, folderURL) else { throw SafetyError.trashUnavailable }
            do {
                try writeRecoveryInstructions(in: folder, boundary: boundary)
                try writeRecoveryIndex(in: folder, files: files)
            } catch {
                Self.removeEmptyFolder(folder, at: folderURL, named: name, in: parent, subfolders: [])
                throw error
            }
            directory = folder
            url = folderURL
            self.parent = parent
            self.name = name
            usesSubfolders = files.count > RecoveryEntry.filesPerFolder
        }

        func discardEmpty() {
            Self.removeEmptyFolder(directory, at: url, named: name, in: parent, subfolders: subfolders)
        }

        private static func removeEmptyFolder(_ folder: OpenFile, at url: URL, named name: String, in parent: OpenFile,
                                              subfolders: [String]) {
            guard (try? matchesPath(folder, url)) == true else { return }
            for name in subfolders { _ = unlinkat(folder.descriptor, name, AT_REMOVEDIR) }
            for name in ["Restore.txt", "Paths.jsonl"] { _ = unlinkat(folder.descriptor, name, 0) }
            _ = unlinkat(parent.descriptor, name, AT_REMOVEDIR)
        }

        func sendToTrash(boundary: VolumeBoundary, using trashFolder: (URL) throws -> URL) throws -> URL {
            _ = try boundary.openRoot()
            guard try matchesPath(directory, url),
                  try NodeMetadata.at(url).identity == directory.metadata().identity else {
                throw SafetyError.fileChanged
            }
            return try trashFolder(url)
        }

        func move(_ candidate: CleanableFile, at offset: Int, from target: ValidatedTarget,
                  boundary: VolumeBoundary) throws {
            let name = candidate.name
            try Task.checkCancellation()
            let entry = RecoveryEntry(candidate: candidate, offset: offset, usesSubfolders: usesSubfolders)
            let destination: OpenFile
            let destinationURL: URL
            if let subfolder = entry.subfolder {
                if activeSubfolder?.name != subfolder {
                    guard mkdirat(directory.descriptor, subfolder, 0o700) == 0 else { throw currentPOSIXError() }
                    subfolders.append(subfolder)
                    let child = try OpenFile(directory: subfolder, in: directory)
                    guard FilesystemIdentity(try child.filesystem()) == boundary.volume.filesystemID else {
                        throw SafetyError.trashUnavailable
                    }
                    activeSubfolder = (subfolder, child)
                }
                guard let child = activeSubfolder?.file else { throw SafetyError.trashUnavailable }
                destination = child
                destinationURL = url.appending(component: subfolder, directoryHint: .isDirectory)
            } else {
                destination = directory
                destinationURL = url
            }

            guard try matchesPath(destination, destinationURL) else { throw SafetyError.trashUnavailable }
            try verifyBeforeMutation(candidate, target: target, boundary: boundary)
            try Task.checkCancellation()

            let source = target.parent.descriptor
            if supportsExclusiveRename {
                if renameatx_np(source, name, destination.descriptor, entry.name, UInt32(RENAME_EXCL)) == 0 { return }
                let error = currentPOSIXError()
                guard error.code == .ENOTSUP else { throw error }
                supportsExclusiveRename = false
            }
            // FSKit exFAT rejects RENAME_EXCL. This destination is inside a newly created per-cleanup directory.
            guard try !entryExists(entry.name, in: destination.descriptor) else { throw POSIXError(.EEXIST) }
            guard renameat(source, name, destination.descriptor, entry.name) == 0 else { throw currentPOSIXError() }
        }
    }

    private static func verifyBeforeMutation(_ candidate: CleanableFile, target: ValidatedTarget,
                                             boundary: VolumeBoundary) throws {
        try boundary.volume.verify()
        guard try matchesPath(target.root, boundary.root),
              try matchesPath(target.parent, target.url.deletingLastPathComponent()),
              try target.file.metadata() == candidate.metadata,
              try NodeMetadata.named(candidate.name, in: target.parent.descriptor) == candidate.metadata else {
            throw SafetyError.fileChanged
        }
        try verifyNoCompanion(to: candidate.name, in: target.parent.descriptor)
    }

    private struct RecoveryEntry: Encodable {
        static let filesPerFolder = 512
        let subfolder: String?
        let name: String
        let path: String

        init(candidate: CleanableFile, offset: Int, usesSubfolders: Bool) {
            path = candidate.relativePath.joined(separator: "/")
            // Avoid Finder's special handling of .DS_Store and ._ names.
            if usesSubfolders {
                subfolder = "Batch-\(offset / Self.filesPerFolder + 1)"
                let prefix = candidate.kind == .appleDouble ? "AD" : "DS"
                name = "\(prefix)\(offset % Self.filesPerFolder + 1)"
            } else {
                subfolder = nil
                let kind = candidate.kind == .appleDouble ? "AppleDouble" : "DS_Store"
                name = "\(kind)-\(candidate.id.uuidString)"
            }
        }

        private enum CodingKeys: String, CodingKey { case file, path }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(subfolder.map { "\($0)/\(name)" } ?? name, forKey: .file)
            try container.encode(path, forKey: .path)
        }
    }

    private static func writeRecoveryIndex(in folder: OpenFile, files: [CleanableFile]) throws {
        let descriptor = openat(folder.descriptor, "Paths.jsonl", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        let index = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let encoder = JSONEncoder()
        var buffer = Data()
        for (offset, file) in files.enumerated() {
            try Task.checkCancellation()
            let entry = RecoveryEntry(candidate: file, offset: offset, usesSubfolders: files.count > RecoveryEntry.filesPerFolder)
            buffer.append(try encoder.encode(entry))
            buffer.append(0x0a)
            if buffer.count >= 64 * 1024 {
                try index.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try index.write(contentsOf: buffer) }
        try Task.checkCancellation()
        // Commit every recovery path before moving the first file.
        try index.synchronize()
        try index.close()
    }

    private static func writeRecoveryInstructions(in folder: OpenFile, boundary: VolumeBoundary) throws {
        let descriptor = openat(folder.descriptor, "Restore.txt", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let path = boundary.root.path(percentEncoded: false)
        let volume = boundary.volume
        let relative = ScopePath.relative(boundary.root, under: volume.url)?.joined(separator: "/") ?? ""
        let instructions = """
        原扫描范围 / Original scan folder
        \(path)

        卷 UUID / Volume UUID: \(volume.persistentID ?? "—")
        扫描范围相对卷的位置 / Scan folder relative to the volume: \(relative.isEmpty ? "." : relative)

        磁盘改名或重新挂载时，请在同一卷内按上面的相对位置找到扫描范围。
        If the drive was renamed or remounted, use the relative location above on the same volume.

        打开 Paths.jsonl，查找恢复文件夹内的相对路径（file）及原相对路径（path）。
        用终端的 mv -n 将文件移回同一磁盘的原路径并恢复原文件名。只恢复仍在这个文件夹里的文件。
        例如 mv -n "/废纸篓路径/保存名" "/原扫描范围/相对路径"。用引号包住完整路径。
        原位置已有同名文件时，请先核对后再恢复。

        Open Paths.jsonl and look up the path inside the recovery folder (file) and the original path (path), relative to the scan folder above.
        In Terminal, use mv -n to move the file back to its original path on the same drive, including its original name.
        For example, mv -n "/path/to/trash/saved-name" "/original-scan-folder/relative-path". Quote both full paths.
        Restore only files present in this folder and check for conflicts first.
        """
        try handle.write(contentsOf: Data(instructions.utf8))
        try handle.synchronize()
        try handle.close()
    }

    private static func validate(_ candidate: CleanableFile, boundary: VolumeBoundary) throws -> ValidatedTarget {
        let url = try boundary.fileURL(candidate.relativePath)
        guard ScopePath.same(url, candidate.url), FileKind.matching(candidate.name) == candidate.kind,
              candidate.metadata.isRegular, candidate.metadata.identity.device == boundary.volume.node.device else {
            throw SafetyError.outsideScope
        }

        let root = try boundary.openRoot()
        let filesystem = try root.filesystem()
        guard filesystem.f_flags & UInt32(MNT_RDONLY) == 0 else { throw SafetyError.readOnly }
        let parentURL = try boundary.directoryURL(Array(candidate.relativePath.dropLast()))
        let parent = try OpenFile(at: parentURL, directory: true)
        guard try parent.metadata().identity == candidate.parent,
              FilesystemIdentity(try parent.filesystem()) == boundary.volume.filesystemID else {
            throw SafetyError.fileChanged
        }
        guard faccessat(parent.descriptor, ".", W_OK | X_OK, AT_EACCESS) == 0 else {
            throw currentPOSIXError()
        }
        let metadata: NodeMetadata
        do {
            metadata = try NodeMetadata.named(candidate.name, in: parent.descriptor)
        } catch let error as POSIXError where error.code == .ENOENT {
            // A missing leaf is conclusive only while the scanned directory and volume still match.
            try boundary.volume.verify()
            guard try matchesPath(root, boundary.root), try matchesPath(parent, parentURL) else {
                throw SafetyError.fileChanged
            }
            throw SafetyError.fileMissing
        }
        guard metadata == candidate.metadata else {
            throw SafetyError.fileChanged
        }
        let file = try OpenFile(at: url)
        guard try file.metadata() == candidate.metadata,
              FilesystemIdentity(try file.filesystem()) == boundary.volume.filesystemID else {
            throw SafetyError.fileChanged
        }
        if candidate.kind == .appleDouble, try !AppleDoubleValidator.isValid(file, size: candidate.bytes) {
            throw SafetyError.invalidAppleDouble
        }

        guard try matchesPath(parent, parentURL), try matchesPath(file, url) else {
            throw SafetyError.fileChanged
        }
        try verifyNoCompanion(to: candidate.name, in: parent.descriptor)
        return ValidatedTarget(url: url, root: root, parent: parent, file: file)
    }

    private static func entryExists(_ name: String, in directory: Int32) throws -> Bool {
        do {
            _ = try NodeMetadata.named(name, in: directory)
            return true
        } catch let error as POSIXError where error.code == .ENOENT || error.code == .ENAMETOOLONG {
            return false
        }
    }

    private static func verifyNoCompanion(to name: String, in directory: Int32) throws {
        // Keep the selection requirement even when the file will be moved by descriptor.
        if try entryExists("._" + name, in: directory) { throw SafetyError.companionPresent }
    }

    private static func matchesPath(_ file: OpenFile, _ url: URL) throws -> Bool {
        let current = try URL(filePath: file.currentPath())
        return ScopePath.same(current, url)
    }
}
