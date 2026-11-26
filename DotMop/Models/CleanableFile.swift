import Foundation

enum FileKind: String, CaseIterable, Sendable {
    case dsStore, appleDouble

    var label: String { self == .dsStore ? ".DS_Store" : "AppleDouble" }

    static func matching(_ name: String) -> Self? {
        if name == ".DS_Store" { return .dsStore }
        if name.utf8.count > 2 && name.utf8.starts(with: [0x2e, 0x5f]) { return .appleDouble }
        return nil
    }
}

struct CleanableFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let relativePath: [String]
    let kind: FileKind
    let metadata: NodeMetadata
    let parent: NodeIdentity
    let originalExists: Bool?

    var name: String { relativePath.last ?? url.lastPathComponent }
    var bytes: Int64 { metadata.size }
    var modified: Date { metadata.modified.date }
    func matchesSearch(_ query: String) -> Bool {
        query.isEmpty || name.localizedStandardContains(query)
            || url.path(percentEncoded: false).localizedStandardContains(query)
    }
}

struct FileTally: Codable, Equatable, Sendable {
    var count = 0
    var bytes: Int64 = 0

    mutating func add(_ size: Int64) {
        count += 1
        bytes += size
    }

    mutating func remove(_ size: Int64) {
        count -= 1
        bytes -= size
    }
}

struct ScanStatistics: Equatable, Sendable {
    var dsStore = FileTally()
    var appleDouble = FileTally()

    var count: Int { dsStore.count + appleDouble.count }

    mutating func add(_ file: CleanableFile) {
        switch file.kind {
        case .dsStore: dsStore.add(file.bytes)
        case .appleDouble: appleDouble.add(file.bytes)
        }
    }

    mutating func remove(_ file: CleanableFile) {
        switch file.kind {
        case .dsStore: dsStore.remove(file.bytes)
        case .appleDouble: appleDouble.remove(file.bytes)
        }
    }
}
