import Darwin
import Foundation
@testable import DotMop

func createFixtureDirectory() throws -> URL {
    let temporary = FileManager.default.temporaryDirectory
    guard let canonicalPath = temporary.withUnsafeFileSystemRepresentation({ realpath($0, nil) }) else {
        throw currentPOSIXError()
    }
    defer { free(canonicalPath) }
    let directory = URL(filePath: String(cString: canonicalPath), directoryHint: .isDirectory)
        .appending(path: "DotMopTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func withFixture<T>(_ operation: (URL) throws -> T) throws -> T {
    let directory = try createFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    return try operation(directory)
}

let appleDoubleFixture = Data([
    0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    0, 0, 0, 9, 0, 0, 0, 38, 0, 0, 0, 4,
    1, 2, 3, 4
])

func fixtureBoundary(_ root: URL) throws -> VolumeBoundary {
    try VolumeBoundary(volume: VolumeReference(url: root, persistentID: nil), root: root)
}
