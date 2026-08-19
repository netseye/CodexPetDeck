import Foundation

/// V2PacketCodec 依赖的 Data 小端扩展(自 ScreenKeySwiftUI 工程同款实现 —
/// 该工程为自有代码; 原文件内联在 PacketCodec.swift, 这里独立成文件)。
extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    /// 从 startIndex+offset 读小端 u32。
    func uint32LittleEndian(at offset: Int) -> UInt32? {
        let start = startIndex + offset
        guard start + 4 <= endIndex else { return nil }
        return UInt32(self[start])
            | (UInt32(self[start + 1]) << 8)
            | (UInt32(self[start + 2]) << 16)
            | (UInt32(self[start + 3]) << 24)
    }
}
