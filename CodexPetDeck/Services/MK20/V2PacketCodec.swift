import Foundation

/// 命令值来自官方宿主 QMetaEnum 键表(声明序 0–15),demo/固件另有 16 SHOW_JPG。
/// 命令 8–17 要求设备 protocolVersion == 2(V2.x 固件),见 PROTOCOL.md §2。
enum V2Command: UInt32 {
    case findDevice = 0
    case sendSystemData = 1
    case reload = 2
    case getTheme = 3
    case setBacklight = 4
    /// 固件跳转表落入 default,无 handler — 仅作已知值解析,不发送。
    case setScanState = 5
    case fileStart = 6
    case fileEnd = 7
    case getVersion = 8
    case setCanvasFlip = 9
    case getScreenMessage = 10
    case deleteTheme = 11
    case sendPixmap = 12
    case proactiveEvent = 13
    case requestUploadKey = 14
    case sendJSON = 15
    /// V2.30+ JSON-RPC 信道(2026-08-17 真机全通): 请求/应答双向同号, V2 帧(A1A55A5E 同步字),
    /// 应答 payload {"ack_method",...} 且帧头 id 回显请求 id。connect 握手等键控状态仍走 sendJSON(15)。
    case rpcJSON = 101
    /// 仅 demo 固件的屏幕镜像页使用;官方 V2 枚举表无此项。
    case showJPEG = 16
}

/// id 字段实际是 DATA_PACKET_TYPE,不是序号:设备应答恒为 2 (CMD_ACK)。
enum V2PacketType: UInt32 {
    case command = 0
    case file = 1
    case commandAcknowledgement = 2
    case fileAcknowledgement = 3
}

struct V2Packet: Equatable {
    let id: UInt32
    let command: UInt32
    let payload: Data
}

/// The production MK20 application serializes command payload dictionaries with
/// Qt's default QDataStream settings: big-endian integers and UTF-16 QStrings.
/// Only the QMap<QString, QString> subset used by the device protocol is needed.
enum QtDataStreamError: LocalizedError {
    case truncated
    case invalidLength
    case invalidString

    var errorDescription: String? {
        switch self {
        case .truncated: "Qt 数据流不完整"
        case .invalidLength: "Qt 数据流长度无效"
        case .invalidString: "Qt 数据流字符串无效"
        }
    }
}

enum QtDataStream {
    static func encodeStringMap(_ values: [String: String]) -> Data {
        var result = Data()
        result.appendBigEndian(UInt32(values.count))
        for key in values.keys.sorted() {
            appendQString(key, to: &result)
            appendQString(values[key] ?? "", to: &result)
        }
        return result
    }

    static func decodeStringMap(_ data: Data) throws -> [String: String] {
        var reader = Reader(data: data)
        let count = try reader.readCollectionSize()
        guard count <= 4_096 else { throw QtDataStreamError.invalidLength }

        var result: [String: String] = [:]
        result.reserveCapacity(count)
        for _ in 0..<count {
            let key = try reader.readQString()
            let value = try reader.readQString()
            result[key] = value
        }
        return result
    }

    private static func appendQString(_ value: String, to data: inout Data) {
        let codeUnits = Array(value.utf16)
        data.appendBigEndian(UInt32(codeUnits.count * 2))
        for codeUnit in codeUnits {
            data.append(UInt8(codeUnit >> 8))
            data.append(UInt8(codeUnit & 0xFF))
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func readCollectionSize() throws -> Int {
            let shortSize = try readUInt32()
            if shortSize == UInt32.max { return 0 }
            if shortSize == 0xFFFF_FFFE {
                let longSize = try readUInt64()
                guard longSize <= UInt64(Int.max) else { throw QtDataStreamError.invalidLength }
                return Int(longSize)
            }
            return Int(shortSize)
        }

        mutating func readQString() throws -> String {
            let byteCount = try readCollectionSize()
            guard byteCount.isMultiple(of: 2), byteCount <= data.count - offset else {
                throw QtDataStreamError.invalidLength
            }

            var codeUnits: [UInt16] = []
            codeUnits.reserveCapacity(byteCount / 2)
            for _ in 0..<(byteCount / 2) {
                let high = UInt16(data[offset])
                let low = UInt16(data[offset + 1])
                codeUnits.append((high << 8) | low)
                offset += 2
            }
            guard let value = String(bytes: codeUnits.flatMap {
                [UInt8($0 & 0xFF), UInt8($0 >> 8)]
            }, encoding: .utf16LittleEndian) else {
                throw QtDataStreamError.invalidString
            }
            return value
        }

        mutating func readUInt32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw QtDataStreamError.truncated }
            let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            return value
        }

        mutating func readUInt64() throws -> UInt64 {
            guard offset + 8 <= data.count else { throw QtDataStreamError.truncated }
            let value = data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            offset += 8
            return value
        }
    }
}

final class V2PacketEncoder {
    static let header = Data("AA551234 FIXEDCMDHEAD ".utf8)
    static let fixedHeaderSize = header.count + 16

    /// V2 帧(cmd=100/101)同步字: fromHex("A1A55A5E") — 固件静态初始化字面量 @0x20e5d4,
    /// 2026-08-17 真机抓包 12/12 帧实证(设备 keyStateChanged RPC 上报全用此头)。
    static let rpcSync = Data([0xA1, 0xA5, 0x5A, 0x5E])
    static let rpcHeaderSize = rpcSync.count + 16

    /// §8.1 帧外 ASCII 控制消息: 上传前与 FILE_END 后各发一次(后者不等回复 — 它才触发应答)。
    static let abortTransferMessage = Data("AA551234 Abort file transfer 123455AA".utf8)

    func encode(command: UInt32, payload: Data, id: UInt32 = 0) -> Data {
        // cmd=100/101 走 V2 双 CRC 帧: sync + id + cmd + size + crc32(size4B) + payload + crc32(payload)。
        // id 字段是请求计数(应答帧原样回显 — RPC 配对机制), DATA_PACKET_TYPE 语义不适用。
        if command >= 100 {
            var result = Self.rpcSync
            result.appendLittleEndian(id)
            result.appendLittleEndian(command)
            let sizeBytes = withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Data($0) }
            result.append(sizeBytes)
            result.appendLittleEndian(CRC32.checksum(sizeBytes))
            result.append(payload)
            result.appendLittleEndian(CRC32.checksum(payload))
            return result
        }
        var result = Self.header
        result.appendLittleEndian(id)
        result.appendLittleEndian(command)
        result.appendLittleEndian(UInt32(payload.count))
        result.appendLittleEndian(CRC32.checksum(payload))
        result.append(payload)
        return result
    }

    func encode(command: V2Command, payload: Data, id: UInt32 = 0) -> Data {
        encode(command: command.rawValue, payload: payload, id: id)
    }

    /// cmd=1 直接携带 QDataStream 的 QMap 原始字节。
    /// 官方 ScreenKeyMacOS 的 host_set_device_system_data() 不会再套 Base64。
    func encodeSystemData(_ values: [String: String]) -> Data {
        encode(command: .sendSystemData, payload: QtDataStream.encodeStringMap(values))
    }

    /// cmd=6/7 参数为 §6 键值流 `{路径: 尺寸/crc32 十进制文本}`(非 JSON、非 QVariant)。
    func encodeFileCommand(_ command: V2Command, path: String, value: String) -> Data {
        encode(command: command, payload: QtDataStream.encodeStringMap([path: value]))
    }
}

final class V2PacketParser {
    private var buffer = Data()
    private let maximumPayloadSize = 16 * 1_024 * 1_024

    func append(_ data: Data) -> [V2Packet] {
        buffer.append(data)
        var packets: [V2Packet] = []

        while true {
            // 先剥离帧外 Abort 控制消息(§8.1) — 不是帧, 不产出 packet。
            if let abortRange = buffer.range(of: V2PacketEncoder.abortTransferMessage) {
                buffer.removeSubrange(abortRange)
                continue
            }
            // 双同步字: V1 (AA551234 FIXEDCMDHEAD ) 与 V2 RPC (A1A55A5E), 取更靠前者。
            let v1Range = buffer.range(of: V2PacketEncoder.header)
            let v2Range = buffer.range(of: V2PacketEncoder.rpcSync)

            guard let headerRange: Range<Data.Index> = {
                switch (v1Range, v2Range) {
                case (nil, nil): return nil
                case (nil, .some(let r)): return r
                case (.some(let r), nil): return r
                case (.some(let a), .some(let b)): return a.lowerBound <= b.lowerBound ? a : b
                }
            }() else {
                retainPossibleHeaderPrefix()
                break
            }

            if headerRange.lowerBound > buffer.startIndex {
                buffer = Data(buffer[headerRange.lowerBound...])
            }

            let isV2 = buffer.starts(with: V2PacketEncoder.rpcSync)
                && !buffer.starts(with: V2PacketEncoder.header)
            let syncLength = isV2 ? V2PacketEncoder.rpcSync.count : V2PacketEncoder.header.count
            let headerSize = isV2 ? V2PacketEncoder.rpcHeaderSize : V2PacketEncoder.fixedHeaderSize

            guard buffer.count >= headerSize else { break }

            guard
                let identifier = buffer.uint32LittleEndian(at: syncLength),
                let command = buffer.uint32LittleEndian(at: syncLength + 4),
                let payloadSize = buffer.uint32LittleEndian(at: syncLength + 8),
                let expectedCRC = buffer.uint32LittleEndian(at: syncLength + 12)
            else { break }

            guard payloadSize <= maximumPayloadSize else {
                buffer = Data(buffer.dropFirst(syncLength))
                continue
            }

            // V2 帧载荷后多 4 字节尾 CRC。
            let totalSize = headerSize + Int(payloadSize) + (isV2 ? 4 : 0)
            guard buffer.count >= totalSize else { break }

            let payload = buffer.subdata(in: headerSize..<headerSize + Int(payloadSize))
            let validCRC: Bool
            if isV2 {
                // V2 头部 CRC 覆盖 size 字段本身(不是 payload)。
                let sizeBytes = withUnsafeBytes(of: payloadSize.littleEndian) { Data($0) }
                validCRC = CRC32.checksum(sizeBytes) == expectedCRC
            } else {
                validCRC = CRC32.checksum(payload) == expectedCRC
            }
            guard validCRC else {
                buffer = Data(buffer.dropFirst(syncLength))
                continue
            }

            packets.append(V2Packet(id: identifier, command: command, payload: payload))
            // Re-wrap the slice so the next frame starts at collection index 0.
            // Data.removeFirst() may retain a non-zero startIndex.
            buffer = Data(buffer.dropFirst(totalSize))
        }

        return packets
    }

    private func retainPossibleHeaderPrefix() {
        // 两种帧头各自保留可能的前缀(V2 的 4B 同步字最长公共前缀按其长度算)。
        let prefixes: [Data] = [V2PacketEncoder.header, V2PacketEncoder.rpcSync]
        var retained: Data?
        for prefix in prefixes {
            let maximumPrefixLength = min(buffer.count, prefix.count - 1)
            guard maximumPrefixLength > 0 else { continue }
            for length in stride(from: maximumPrefixLength, through: 1, by: -1) {
                let candidate = buffer.suffix(length)
                if candidate == prefix.prefix(length) {
                    if retained == nil || candidate.count > retained!.count {
                        retained = Data(candidate)
                    }
                    break
                }
            }
        }
        if let retained {
            buffer = retained
        } else {
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

/// cmd=3 主题清单的条目:设备绝对路径 + 十进制 CRC 字符串。
struct DeviceTheme: Identifiable, Equatable {
    let path: String
    let crc: String

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// cmd=13 设备主动上报的按键/旋钮事件(QVariant 双子 map,PROTOCOL.md §7)。
/// map1 = {type:'keyState', row, col, pressed}, map2 = 触发键的 widget 元数据。
/// 已知不稳定且 keyboard 型键不上报(设备直接执行 HID);仅作诊断显示;按键可靠通路是 HID 键盘接口。
struct V2ProactiveEvent: Equatable {
    /// 值为 QString / Int32(已转字符串)/ null(以 nil 表示)。
    let fields: [String: String?]

    var type: String? { fields["type"] ?? nil }
    var row: Int? { (fields["row"] ?? nil).flatMap(Int.init) }
    var col: Int? { (fields["col"] ?? nil).flatMap(Int.init) }

    /// MK20 keyState uses 0 for key-down and 1 for key-up.
    var isPressed: Bool? {
        guard let raw = fields["pressed"] ?? nil else { return nil }
        return raw == "0"
    }

    var summary: String {
        let ordered = ["keyState", "row", "col", "keycode", "keyString", "pageSwitch"]
            .compactMap { name -> String? in
                guard let value = fields[name] ?? nil else { return nil }
                return "\(name)=\(value)"
            }
        return ordered.joined(separator: " ")
    }

    /// 编码器伪行(§9.4): row==col 且 100-105 时为编码器事件(无抬起, 不映射键格)。
    /// 100=左旋钮按下, 101/102=左方向, 103=右旋钮按下, 104/105=右方向。
    var encoderLabel: String? {
        guard let rowValue = fields["row"] ?? nil, let row = Int(rowValue),
              let colValue = fields["col"] ?? nil, let col = Int(colValue),
              row == col, (100...105).contains(row) else { return nil }
        return switch row {
        case 100: "左旋钮 按下"
        case 101: "左旋钮 顺时针"
        case 102: "左旋钮 逆时针"
        case 103: "右旋钮 按下"
        case 104: "右旋钮 顺时针"
        default: "右旋钮 逆时针"
        }
    }
}

/// 设备→宿主命令载荷里的大端嵌套结构(§6/§7):
/// §6(cmd=0/3/10 及 cmd=6/7 参数): `[count u32be]` + 每项 `[klen][key][vlen][value]` 全文本,无类型标签。
/// §7(cmd=13): `[u32 版本=2]` + 多个「计数子 map」`[u32 count] + count 个字段`:
///   `[klen u32be][key utf16be][qtype u32be][isNull u8][载荷]` —
///   qtype 0x02=int32([i32 BE]), 0x0a=QString([u32 vlen][utf16be], 0xFFFFFFFF=null);
///   isNull≠0 时无载荷。与 .Theme 文件内部编码同源(Qt QVariant 标准)。
enum V2NestedDecoder {
    static func decodeThemeList(_ data: Data) throws -> (themes: [DeviceTheme], storage: [String: String]) {
        var reader = QtNestedReader(data: data)
        let count = try reader.readCount()
        var values: [String: String] = [:]
        for _ in 0..<count {
            let key = try reader.readUTF16BEString()
            let value = try reader.readUTF16BEString()
            values[key] = value
        }

        let themes = values
            .filter { $0.key.hasPrefix("/") && $0.key.hasSuffix(".Theme") }
            .sorted { $0.key < $1.key }
            .map { DeviceTheme(path: $0.key, crc: $0.value) }
        return (themes, values)
    }

    /// cmd=13: QVariant 子 map 序列(2026-08-15 破译, 420B 真机帧逐字节验证;
    /// 同日与 MK20Control 独立逆向交叉确认)。双子 map: keyState + widget 描述。
    static func decodeProactiveEvents(_ data: Data) throws -> [V2ProactiveEvent] {
        var reader = QtNestedReader(data: data)
        guard let version = try? reader.readUInt32(), version == 2 else {
            throw QtDataStreamError.invalidLength
        }

        var events: [V2ProactiveEvent] = []
        // 子 map 连续排布,直到流尾或格式不再合法。
        while reader.remainingBytes > 0 {
            guard let map = try? reader.readVariantMap() else { break }
            if !map.isEmpty { events.append(V2ProactiveEvent(fields: map)) }
        }
        return events
    }
}

private struct QtNestedReader {
    let data: Data
    var offset = 0

    var remainingBytes: Int { data.count - offset }

    mutating func readCount() throws -> Int {
        let raw = try readUInt32()
        guard raw != UInt32.max, raw <= 4_096 else { throw QtDataStreamError.invalidLength }
        return Int(raw)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw QtDataStreamError.truncated }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readUTF16BEString() throws -> String {
        let byteCount = Int(try readUInt32())
        guard byteCount >= 0, byteCount.isMultiple(of: 2), byteCount <= data.count - offset else {
            throw QtDataStreamError.invalidLength
        }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(byteCount / 2)
        var index = offset
        while index < offset + byteCount {
            codeUnits.append((UInt16(data[index]) << 8) | UInt16(data[index + 1]))
            index += 2
        }
        offset += byteCount
        guard let value = String(bytes: codeUnits.flatMap {
            [UInt8($0 >> 8), UInt8($0 & 0xFF)]
        }, encoding: .utf16BigEndian) else {
            throw QtDataStreamError.invalidString
        }
        return value
    }

    /// QVariant 子 map: [u32 count] + count 个 [klen][key][qtype][isNull][载荷]。
    /// 仅实现 cmd=13 用到的 int32/QString;其它 qtype 抛错(见 PROTOCOL.md §7)。
    mutating func readVariantMap() throws -> [String: String?] {
        let count = try readCount()
        var map: [String: String?] = [:]
        for _ in 0..<count {
            let key = try readUTF16BEString()
            let qtype = try readUInt32()
            let isNull = try readByte()
            if isNull != 0 {
                map[key] = nil
                continue
            }
            switch qtype {
            case 0x0a: // QString: [u32 vlen][utf16be]; 0xFFFFFFFF = null
                let vlen = try readUInt32()
                if vlen == UInt32.max {
                    map[key] = nil
                } else {
                    guard vlen.isMultiple(of: 2), Int(vlen) <= data.count - offset else {
                        throw QtDataStreamError.invalidLength
                    }
                    map[key] = try readRawUTF16BE(byteCount: Int(vlen))
                }
            case 0x02: // int32 BE
                let value = try readUInt32()
                map[key] = String(Int32(bitPattern: value))
            default:
                throw QtDataStreamError.invalidLength
            }
        }
        return map
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw QtDataStreamError.truncated }
        let value = data[offset]
        offset += 1
        return value
    }

    /// 不含长度前缀的定长 UTF-16BE 解码(readVariantMap 内部用)。
    private mutating func readRawUTF16BE(byteCount: Int) throws -> String {
        guard byteCount.isMultiple(of: 2), byteCount <= data.count - offset else {
            throw QtDataStreamError.invalidLength
        }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(byteCount / 2)
        var index = offset
        while index < offset + byteCount {
            codeUnits.append((UInt16(data[index]) << 8) | UInt16(data[index + 1]))
            index += 2
        }
        offset += byteCount
        guard let value = String(bytes: codeUnits.flatMap {
            [UInt8($0 >> 8), UInt8($0 & 0xFF)]
        }, encoding: .utf16BigEndian) else {
            throw QtDataStreamError.invalidString
        }
        return value
    }
}
