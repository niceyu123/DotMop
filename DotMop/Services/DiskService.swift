import Darwin
import DiskArbitration
import Foundation
import IOKit

struct VolumeClassification {
    let isLocal: Bool
    let isInternal: Bool?
    let isRemovable: Bool
    let transport: String?
    let isStartup: Bool
    let fileSystem: String
    let apfsRole: Int?

    private static let physicalTransports: Set<String> = [
        "usb", "usb4", "thunderbolt", "firewire", "secure digital", "sd", "sdxc",
        "sata", "ata", "serial ata", "sas", "scsi", "pci", "pci-express", "pcie", "nvme"
    ]

    var isExternal: Bool {
        guard isLocal, !isStartup, let transport = transport?.lowercased(),
              Self.physicalTransports.contains(transport) else { return false }
        let sdCard = ["secure digital", "sd", "sdxc"].contains(transport) && isRemovable
        guard isInternal == false || sdCard else { return false }
        // APFS volumes with system or backup roles are outside the cleaner's scope.
        return fileSystem != "apfs" || apfsRole == 0
    }
}

enum DiskService {
    private static let keys: Set<URLResourceKey> = [
        .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey,
        .volumeLocalizedFormatDescriptionKey, .volumeNameKey, .volumeUUIDStringKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey
    ]

    static func discover(authorizedRoots: [URL]?) -> [DiskInfo] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: authorizedRoots == nil ? Array(keys) : nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        var seen: Set<String> = []
        return urls.filter { url in
            authorizedRoots?.contains { ScopePath.same($0, url) } ?? true
        }
            .compactMap { diskInfo(at: $0, session: session) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func externalDisk(at root: URL) -> DiskInfo? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                                  options: [.skipHiddenVolumes])?
                .first(where: { ScopePath.same($0, root) }) else { return nil }
        return diskInfo(at: mounted, session: session)
    }

    private static func diskInfo(at url: URL, session: DASession) -> DiskInfo? {
        guard let values = try? url.resourceValues(forKeys: keys),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let kind = description[kDADiskDescriptionVolumeKindKey as String] as? String,
              let fs = try? VolumeReference.filesystem(at: url) else { return nil }
        let startup = fs.f_flags & UInt32(MNT_ROOTFS) != 0 || url.path == "/"
        let diskInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
        let isInternal = diskInternal == true || values.volumeIsInternal == true
            ? true : (diskInternal ?? values.volumeIsInternal)
        let classification = VolumeClassification(
            isLocal: values.volumeIsLocal == true && fs.f_flags & UInt32(MNT_LOCAL) != 0,
            isInternal: isInternal,
            isRemovable: values.volumeIsRemovable == true
                || description[kDADiskDescriptionMediaRemovableKey as String] as? Bool == true,
            transport: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            isStartup: startup,
            fileSystem: kind,
            apfsRole: kind == "apfs" && !startup ? apfsRole(of: disk) : nil
        )
        guard classification.isExternal else { return nil }
        if kind == "hfs", (try? hasLegacyBackup(at: url)) == true { return nil }
        let identity = values.volumeUUIDString?.lowercased() ?? diskUUID(in: description)
        guard let volume = try? VolumeReference(url: url, persistentID: identity) else { return nil }
        return DiskInfo(
            volume: volume,
            name: values.volumeName ?? url.lastPathComponent,
            format: values.volumeLocalizedFormatDescription ?? kind.uppercased(),
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            availableBytes: values.volumeAvailableCapacity.map(Int64.init),
            isReadOnly: values.volumeIsReadOnly == true || fs.f_flags & UInt32(MNT_RDONLY) != 0
        )
    }

    static func verifyBackupStatus(of volume: VolumeReference) throws {
        try volume.verify()
        let info = try VolumeReference.filesystem(at: volume.url)
        var type = info.f_fstypename
        let kind = withUnsafeBytes(of: &type) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        if kind == "hfs" {
            guard try !hasLegacyBackup(at: volume.url) else { throw SafetyError.backupVolume }
        } else if kind == "apfs" {
            guard let session = DASessionCreate(kCFAllocatorDefault),
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume.url as CFURL),
                  apfsRole(of: disk) == 0 else { throw SafetyError.backupVolume }
        }
    }

    static func hasLegacyBackup(at root: URL) throws -> Bool {
        let marker = root.appending(component: "Backups.backupdb")
        do {
            _ = try NodeMetadata.at(marker)
            return true
        } catch let error as POSIXError where error.code == .ENOENT {
            return false
        }
    }

    private static func apfsRole(of disk: DADisk) -> Int? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        // Disk Arbitration returns the IOMedia for this APFS volume, rather than for its container.
        let property = IORegistryEntryCreateCFProperty(media, "RoleValue" as CFString, kCFAllocatorDefault, 0)
        return (property?.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func diskUUID(in description: [String: Any]) -> String? {
        guard let value = description[kDADiskDescriptionVolumeUUIDKey as String],
              CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        // CFTypeID has already established the concrete CFUUID type.
        let uuid = unsafeDowncast(value as AnyObject, to: CFUUID.self)
        return (CFUUIDCreateString(kCFAllocatorDefault, uuid) as String).lowercased()
    }
}
