import Foundation
import XCTest
@testable import DotMop

final class DiskTests: XCTestCase {
    func testDiskEligibilityRejectsStartupNetworkVirtualAndBackupVolumes() {
        XCTAssertTrue(VolumeClassification(isLocal: true, isInternal: false, isRemovable: false,
                                           transport: "USB", isStartup: false, fileSystem: "apfs", apfsRole: 0).isExternal)
        XCTAssertTrue(VolumeClassification(isLocal: true, isInternal: true, isRemovable: true,
                                           transport: "Secure Digital", isStartup: false, fileSystem: "exfat", apfsRole: nil).isExternal)
        XCTAssertFalse(VolumeClassification(isLocal: true, isInternal: false, isRemovable: true,
                                            transport: "Virtual Interface", isStartup: false, fileSystem: "apfs", apfsRole: 0).isExternal)
        XCTAssertFalse(VolumeClassification(isLocal: true, isInternal: false, isRemovable: false,
                                            transport: "USB", isStartup: false, fileSystem: "apfs", apfsRole: 384).isExternal)
        XCTAssertFalse(VolumeClassification(isLocal: true, isInternal: false, isRemovable: false,
                                            transport: "USB", isStartup: false, fileSystem: "apfs", apfsRole: nil).isExternal)
        XCTAssertFalse(VolumeClassification(isLocal: true, isInternal: false, isRemovable: false,
                                            transport: "Thunderbolt", isStartup: true, fileSystem: "apfs", apfsRole: 0).isExternal)
        XCTAssertFalse(VolumeClassification(isLocal: false, isInternal: false, isRemovable: true,
                                            transport: "USB", isStartup: false, fileSystem: "smbfs", apfsRole: nil).isExternal)
        XCTAssertFalse(VolumeClassification(isLocal: true, isInternal: nil, isRemovable: true,
                                            transport: nil, isStartup: false, fileSystem: "exfat", apfsRole: nil).isExternal)
    }

    func testBoundaryRejectsSiblingWithCommonPathPrefixAndSymlink() throws {
        try withFixture { base in
            let root = base.appending(path: "Root", directoryHint: .isDirectory)
            let sibling = base.appending(path: "Root2", directoryHint: .isDirectory)
            let link = base.appending(path: "Link", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sibling)
            let volume = try VolumeReference(url: root, persistentID: nil)
            XCTAssertThrowsError(try VolumeBoundary(volume: volume, root: sibling))
            XCTAssertThrowsError(try VolumeBoundary(volume: try VolumeReference(url: base, persistentID: nil), root: link))
            let boundary = try VolumeBoundary(volume: volume, root: root)
            XCTAssertThrowsError(try boundary.fileURL(["..", ".DS_Store"]))
        }
    }

    func testLegacyBackupMarkerExcludesVolume() throws {
        try withFixture { base in
            XCTAssertFalse(try DiskService.hasLegacyBackup(at: base))
            try FileManager.default.createDirectory(at: base.appending(path: "Backups.backupdb"),
                                                    withIntermediateDirectories: false)
            XCTAssertTrue(try DiskService.hasLegacyBackup(at: base))
        }
    }
}
