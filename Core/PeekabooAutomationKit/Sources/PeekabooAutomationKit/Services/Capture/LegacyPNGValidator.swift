import Foundation
import zlib

enum LegacyPNGValidator {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let ihdr: UInt32 = 0x4948_4452
    private static let plte: UInt32 = 0x504C_5445
    private static let idat: UInt32 = 0x4944_4154
    private static let iend: UInt32 = 0x4945_4E44

    static func hasValidStructureAndCRC(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= self.signature.count + 12,
                  self.signature.indices.allSatisfy({ bytes[$0] == self.signature[$0] })
            else { return false }

            var offset = self.signature.count
            var sawIDAT = false
            var idatSequenceEnded = false
            var sawPLTE = false
            var colorType: UInt8?
            var totalIDATBytes: UInt64 = 0

            while offset < bytes.count {
                let remaining = bytes.count - offset
                guard remaining >= 12 else { return false }

                let declaredLength = self.uint32(bytes, at: offset)
                guard let length = Int(exactly: declaredLength),
                      length <= remaining - 12
                else { return false }

                let typeOffset = offset + 4
                let dataOffset = typeOffset + 4
                let crcOffset = dataOffset + length
                let chunkEnd = crcOffset + 4
                let type = self.uint32(bytes, at: typeOffset)
                guard self.isValidChunkType(bytes, at: typeOffset),
                      self.crc32(bytes, from: typeOffset, count: length + 4) == self.uint32(bytes, at: crcOffset)
                else { return false }

                if offset == self.signature.count {
                    guard type == self.ihdr,
                          length == 13,
                          self.validIHDR(bytes, at: dataOffset)
                    else { return false }
                    colorType = bytes[dataOffset + 9]
                } else if type == self.ihdr {
                    return false
                }

                switch type {
                case self.ihdr:
                    break

                case self.plte:
                    guard !sawPLTE,
                          !sawIDAT,
                          (3...768).contains(length),
                          length.isMultiple(of: 3),
                          colorType != 0,
                          colorType != 4
                    else { return false }
                    sawPLTE = true

                case self.idat:
                    guard !idatSequenceEnded else { return false }
                    let (updatedTotal, overflow) = totalIDATBytes.addingReportingOverflow(UInt64(length))
                    guard !overflow else { return false }
                    totalIDATBytes = updatedTotal
                    sawIDAT = true

                case self.iend:
                    guard sawIDAT,
                          totalIDATBytes > 0,
                          length == 0,
                          chunkEnd == bytes.count,
                          colorType != 3 || sawPLTE
                    else { return false }
                    return true

                default:
                    // Unknown critical chunks cannot be safely ignored.
                    guard bytes[typeOffset] >= 0x61 else { return false }
                    if sawIDAT {
                        idatSequenceEnded = true
                    }
                }

                offset = chunkEnd
            }
            return false
        }
    }

    private static func validIHDR(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Bool {
        let width = self.uint32(bytes, at: offset)
        let height = self.uint32(bytes, at: offset + 4)
        let bitDepth = bytes[offset + 8]
        let colorType = bytes[offset + 9]
        let compression = bytes[offset + 10]
        let filter = bytes[offset + 11]
        let interlace = bytes[offset + 12]
        let validBitDepth = switch colorType {
        case 0: [1, 2, 4, 8, 16].contains(bitDepth)
        case 2, 4, 6: [8, 16].contains(bitDepth)
        case 3: [1, 2, 4, 8].contains(bitDepth)
        default: false
        }
        return width > 0 && height > 0 && validBitDepth && compression == 0 && filter == 0 && interlace <= 1
    }

    private static func isValidChunkType(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Bool {
        for index in 0..<4 {
            let byte = bytes[offset + index]
            guard (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) else { return false }
        }
        // The PNG reserved bit must remain zero, represented by an uppercase third letter.
        return (0x41...0x5A).contains(bytes[offset + 2])
    }

    private static func crc32(
        _ bytes: UnsafeRawBufferPointer,
        from offset: Int,
        count: Int) -> UInt32
    {
        guard count > 0, let baseAddress = bytes.baseAddress else { return 0 }
        let pointer = baseAddress.advanced(by: offset).assumingMemoryBound(to: Bytef.self)
        return UInt32(truncatingIfNeeded: zlib.crc32_z(0, pointer, count))
    }

    private static func uint32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
    }
}
