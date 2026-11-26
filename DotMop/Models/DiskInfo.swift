struct DiskInfo: Identifiable, Equatable, Sendable {
    var id: String { volume.id }
    let volume: VolumeReference
    let name: String
    let format: String
    let totalBytes: Int64?
    let availableBytes: Int64?
    let isReadOnly: Bool
}
