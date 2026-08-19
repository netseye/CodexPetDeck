import Foundation

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1
                ? 0xEDB8_8320 ^ (value >> 1)
                : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[tableIndex] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }
}
