import Darwin
import Foundation

enum SafetyError: LocalizedError, Equatable {
    case outsideScope, volumeChanged, scopeChanged, unsafePath
    case backupVolume, readOnly, fileChanged, fileMissing, invalidAppleDouble, companionPresent, trashUnavailable

    var errorDescription: String? {
        switch self {
        case .outsideScope: "请选择当前外置磁盘上的文件夹。"
        case .volumeChanged: "磁盘已断开或卷已变化。"
        case .scopeChanged: "扫描范围已变化，请重新选择文件夹或重新扫描。"
        case .unsafePath: "路径包含符号链接或系统管理目录。"
        case .backupVolume: "已跳过 Time Machine 备份卷或无法验证的旧式备份卷。"
        case .readOnly: "磁盘为只读。"
        case .fileChanged: "文件已移动、被替换或发生变化，请重新扫描。"
        case .fileMissing: "文件已不在扫描时的位置。"
        case .invalidAppleDouble: "AppleDouble 格式校验失败，请重新扫描。"
        case .companionPresent: "系统废纸篓可能一并移动旁边的 ._ 文件，已跳过以保留该文件。"
        case .trashUnavailable: "无法确认此磁盘上的废纸篓位置。"
        }
    }
}

func currentPOSIXError(_ code: Int32 = errno) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

func isFileAccessDenied(_ error: any Error) -> Bool {
    if let posix = error as? POSIXError { return posix.code == .EACCES || posix.code == .EPERM }
    if let cocoa = error as? CocoaError {
        return cocoa.code == .fileReadNoPermission || cocoa.code == .fileWriteNoPermission
    }
    return false
}

struct NodeIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
    }
}

struct NodeTimestamp: Codable, Equatable, Sendable {
    let seconds: Int
    let nanoseconds: Int

    init(_ value: timespec) {
        seconds = value.tv_sec
        nanoseconds = value.tv_nsec
    }

    var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
}

struct NodeMetadata: Equatable, Sendable {
    let identity: NodeIdentity
    let mode: mode_t
    let size: Int64
    let owner: uid_t
    let modified: NodeTimestamp
    let changed: NodeTimestamp
    let created: NodeTimestamp
    let generation: UInt32
    let flags: UInt32

    init(_ value: stat) {
        identity = NodeIdentity(value)
        mode = value.st_mode
        size = value.st_size
        owner = value.st_uid
        modified = NodeTimestamp(value.st_mtimespec)
        changed = NodeTimestamp(value.st_ctimespec)
        created = NodeTimestamp(value.st_birthtimespec)
        generation = value.st_gen
        flags = value.st_flags
    }

    var isRegular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }

    static func at(_ url: URL) throws -> Self {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0, &value) }) == 0 else {
            throw currentPOSIXError()
        }
        return Self(value)
    }

    static func named(_ name: String, in descriptor: Int32) throws -> Self {
        var value = stat()
        guard name.withCString({ fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw currentPOSIXError()
        }
        return Self(value)
    }
}

struct FilesystemIdentity: Equatable, Sendable {
    let first: Int32
    let second: Int32

    init(_ value: statfs) {
        first = value.f_fsid.val.0
        second = value.f_fsid.val.1
    }
}

final class OpenFile {
    let descriptor: Int32

    init(at url: URL, directory: Bool = false) throws {
        let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY
        descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(path, flags | (directory ? O_DIRECTORY : 0))
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
    }

    convenience init(directory name: String, in parent: OpenFile) throws {
        try self.init(name: name, in: parent.descriptor, directory: true)
    }

    init(name: String, in parent: Int32, directory: Bool = false) throws {
        guard ScopePath.isComponent(name) else { throw SafetyError.unsafePath }
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        descriptor = Darwin.openat(parent, name, flags | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw currentPOSIXError() }
    }

    deinit { close(descriptor) }

    func metadata() throws -> NodeMetadata {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw currentPOSIXError() }
        return NodeMetadata(value)
    }

    func filesystem() throws -> statfs {
        var value = statfs()
        guard fstatfs(descriptor, &value) == 0 else { throw currentPOSIXError() }
        return value
    }

    func currentPath() throws -> String {
        try Self.currentPath(of: descriptor)
    }

    static func currentPath(of descriptor: Int32) throws -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { throw currentPOSIXError() }
        guard let path = bytes.withUnsafeBufferPointer({ buffer in
            buffer.baseAddress.flatMap { String(validatingCString: $0) }
        }) else {
            throw SafetyError.unsafePath
        }
        return path
    }
}

enum ScopePath {
    private static let reservedDirectories: Set<String> = [
        ".trashes", ".trash", ".fseventsd", ".spotlight-v100", ".temporaryitems",
        ".documentrevisions-v100", ".mobilebackups", "backups.backupdb",
        ".appledouble", ".appledb", ".appledesktop"
    ]

    static func allowsDirectory(_ name: String) -> Bool {
        let lower = name.lowercased()
        return isComponent(name) && !reservedDirectories.contains(lower)
            && !lower.hasPrefix(".com.apple.timemachine")
    }

    static func isComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(0) && !name.utf8.contains(47)
    }

    static func relative(_ url: URL, under root: URL) -> [String]? {
        guard url.isFileURL, root.isFileURL else { return nil }
        let parts = url.pathComponents
        let prefix = root.pathComponents
        guard parts.starts(with: prefix, by: { $0.utf8.elementsEqual($1.utf8) }) else { return nil }
        let relative = Array(parts.dropFirst(prefix.count))
        return relative.allSatisfy(isComponent) ? relative : nil
    }

    static func same(_ first: URL, _ second: URL) -> Bool {
        first.isFileURL && second.isFileURL
            && first.pathComponents.elementsEqual(second.pathComponents) { $0.utf8.elementsEqual($1.utf8) }
    }
}

struct VolumeReference: Equatable, Sendable {
    let url: URL
    let persistentID: String?
    let node: NodeIdentity
    let filesystemID: FilesystemIdentity

    var id: String {
        "\(node.device)|\(node.inode)|\(filesystemID.first)|\(filesystemID.second)|\(persistentID ?? "")"
    }

    init(url: URL, persistentID: String?) throws {
        let metadata = try NodeMetadata.at(url)
        guard metadata.isDirectory else { throw SafetyError.unsafePath }
        self.url = url
        self.persistentID = persistentID
        node = metadata.identity
        filesystemID = FilesystemIdentity(try Self.filesystem(at: url))
    }

    func verify() throws {
        do {
            let metadata = try NodeMetadata.at(url)
            guard metadata.isDirectory, metadata.identity == node,
                  FilesystemIdentity(try Self.filesystem(at: url)) == filesystemID else {
                throw SafetyError.volumeChanged
            }
        } catch let error as POSIXError where [.ENOENT, .ENOTDIR, .ENODEV, .ENXIO, .ESTALE].contains(error.code) {
            throw SafetyError.volumeChanged
        }
    }

    static func filesystem(at url: URL) throws -> statfs {
        var info = statfs()
        guard url.withUnsafeFileSystemRepresentation({ statfs($0, &info) }) == 0 else {
            throw currentPOSIXError()
        }
        return info
    }
}

struct VolumeBoundary: Equatable, Sendable {
    let volume: VolumeReference
    let root: URL
    let rootID: NodeIdentity

    init(volume: VolumeReference, root: URL) throws {
        guard let relative = ScopePath.relative(root, under: volume.url) else {
            throw SafetyError.outsideScope
        }
        guard relative.allSatisfy(ScopePath.allowsDirectory) else { throw SafetyError.unsafePath }
        try volume.verify()
        let file = try OpenFile(at: root, directory: true)
        let identity = try file.metadata().identity
        guard identity.device == volume.node.device,
              FilesystemIdentity(try file.filesystem()) == volume.filesystemID else {
            throw SafetyError.outsideScope
        }
        self.volume = volume
        self.root = root
        rootID = identity
    }

    func openRoot() throws -> OpenFile {
        try volume.verify()
        let file: OpenFile
        do {
            file = try OpenFile(at: root, directory: true)
        } catch let error as POSIXError where [.ENOENT, .ENOTDIR, .ELOOP].contains(error.code) {
            throw SafetyError.scopeChanged
        }
        guard try file.metadata().identity == rootID,
              FilesystemIdentity(try file.filesystem()) == volume.filesystemID else {
            throw SafetyError.scopeChanged
        }
        return file
    }

    func directoryURL(_ parts: [String]) throws -> URL {
        guard parts.allSatisfy(ScopePath.allowsDirectory) else { throw SafetyError.unsafePath }
        return parts.reduce(root) { $0.appending(component: $1, directoryHint: .isDirectory) }
    }

    func fileURL(_ parts: [String]) throws -> URL {
        guard let name = parts.last, ScopePath.isComponent(name) else { throw SafetyError.outsideScope }
        return try directoryURL(Array(parts.dropLast())).appending(component: name, directoryHint: .notDirectory)
    }
}
