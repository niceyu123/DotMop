import Darwin
import Foundation

enum AppleDoubleValidator {
    static let headerSize = 26
    private static let descriptorSize = 12
    private static let initialReadSize = headerSize + 4 * descriptorSize

    static func isValid(_ file: OpenFile, size: Int64) throws -> Bool {
        guard size >= headerSize,
              let header = try read(file, length: Int(min(size, Int64(initialReadSize))), offset: 0),
              uint32(header, 0) == 0x00051607 else { return false }
        let version = uint32(header, 4)
        guard version == 0x00010000 || version == 0x00020000 else { return false }
        let count = Int(header[24]) << 8 | Int(header[25])
        let tableSize = count * descriptorSize
        let dataStart = Int64(headerSize + tableSize)
        guard count > 0, dataStart <= size else { return false }

        let bytes: [UInt8]
        let start: Int
        if dataStart <= header.count {
            bytes = header
            start = headerSize
        } else {
            guard let table = try read(file, length: tableSize, offset: Int64(headerSize)) else { return false }
            bytes = table
            start = 0
        }

        var ids: Set<UInt32> = []
        var ranges: [Range<Int64>] = []
        for index in stride(from: start, to: start + tableSize, by: descriptorSize) {
            let id = uint32(bytes, index)
            let offset = Int64(uint32(bytes, index + 4))
            let length = Int64(uint32(bytes, index + 8))
            // An AppleDouble header has no data-fork entry. A zero-length entry is legal.
            guard id > 1, ids.insert(id).inserted, offset >= dataStart, offset + length <= size else { return false }
            if length > 0 { ranges.append(offset..<(offset + length)) }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        return zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound }
    }

    private static func uint32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    private static func read(_ file: OpenFile, length: Int, offset: Int64) throws -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: length)
        var completed = 0
        while completed < length {
            let count = bytes.withUnsafeMutableBytes { buffer in
                pread(file.descriptor, buffer.baseAddress?.advanced(by: completed),
                      length - completed, offset + Int64(completed))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            guard count > 0 else { return nil }
            completed += count
        }
        return bytes
    }
}
