import Foundation

/// `.Theme` 内嵌资产(图标/背景/GIF/MP4):设备路径 + 原始字节。
/// 路径命名空间如 `/image/MK20/<主题名>/<文件>.png`(§7)。
struct ThemeAsset: Equatable {
    let path: String
    let data: Data
}

/// 解码后的 `.Theme` 文件。布局 JSON 以原始文本保留 — 不解析成强类型模型,
/// 未识别的 widget/action 字段原样存活,回写不会丢数据。
struct ThemeFile: Equatable {
    var language: Int32 = 1
    /// 92 字节 ASCII(base64 文本原样)。空值时 keyboard 键可用但 text 键完全失灵(真机确认)。
    var keyMacroValue: Data = ThemeFileCodec.defaultKeyMacroValue
    /// 通常为 null(长度哨兵 0xFFFFFFFF 表示)。
    var keyMacro: Data? = nil
    /// 完整布局 JSON 文本({"main":{...},"pages":[...]})。
    var layoutJSON: String
    var assets: [ThemeAsset] = []
}

extension ThemeFileCodec.TaggedValue {
    /// null 字节数组(keyMacro 的常态): 外层 isNull=0 + 载荷长度哨兵 0xFFFFFFFF。
    /// 真机样本确认 — 对 string/byteArray,null 由载荷自身长度字段表示,不是外层标志。
    static var nullByteArray: ThemeFileCodec.TaggedValue { .byteArray(nil) }
}

enum ThemeFileCodecError: LocalizedError, Equatable {
    case truncated(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .truncated(let what): "Theme 文件不完整: 缺少 \(what)"
        case .invalid(let what): "Theme 文件格式无效: \(what)"
        }
    }
}

/// `.Theme` 容器编解码器(MK20Control PROTOCOL §7,真机字节级逆向)。
///
/// 布局:
/// ```
/// [header: QVariant 标签 map — language(int32), keyMacroValue(bytes), keyMacro(bytes|null)]
/// [8B — 4 零字节 + u32BE = JSON 字节数 + 1]
/// [UTF-8 JSON]
/// [1 保留字节 0x0A]
/// [u32BE assetCount] + 每项 [u32BE pathLen][path UTF-16BE][u32BE dataLen][data]
/// [4 零字节尾 — 必需, 缺失时 text 键失灵(真机确认)]
/// ```
enum ThemeFileCodec {
    /// 全部 38 个官方主题携带的同一 92 字节值(base64 ASCII 文本原样写入,不预解码)。
    static let defaultKeyMacroValue = Data(
        "AAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".utf8
    )

    private static let nullLengthSentinel: UInt32 = 0xFFFF_FFFF
    private static let jsonTerminator: UInt8 = 0x0A

    // MARK: - Decoding

    static func decode(_ data: Data) throws -> ThemeFile {
        var reader = TaggedReader(data: data)

        let header = try reader.readTaggedMap()
        guard case .int32(let language) = header["language"] ?? .string(nil) else {
            throw ThemeFileCodecError.invalid("header 缺少 int32 型 language 字段")
        }
        guard case .byteArray(let keyMacroValue) = header["keyMacroValue"] ?? .string(nil),
              let keyMacroValue else {
            throw ThemeFileCodecError.invalid("header 缺少 byteArray 型 keyMacroValue 字段")
        }
        var keyMacro: Data?
        if case .byteArray(let bytes) = header["keyMacro"] ?? .nullByteArray, let bytes {
            keyMacro = bytes
        }

        // 8 字节间隔(4 零 + jsonLen+1):真机确认。解码不信任长度字段 —
        // 平衡括号扫描找 JSON 真实结尾,无论该字段为何值都正确。
        guard reader.remainingBytes >= 8 else {
            throw ThemeFileCodecError.truncated("header 后的 8 字节间隔")
        }
        reader.skip(8)

        let jsonStart = reader.offset
        let jsonEnd = try findJSONEnd(data, from: jsonStart)
        guard let layoutJSON = String(data: data[jsonStart..<(jsonEnd + 1)], encoding: .utf8) else {
            throw ThemeFileCodecError.invalid("布局 JSON 不是有效 UTF-8")
        }
        reader.skip(jsonEnd + 1 - jsonStart)

        if reader.peekByte() == jsonTerminator { reader.skip(1) }

        var assets: [ThemeAsset] = []
        if reader.remainingBytes >= 4 {
            let assetCount = Int(try reader.readUInt32())
            guard assetCount <= 100_000 else {
                throw ThemeFileCodecError.invalid("资产数 \(assetCount) 不可信")
            }
            for index in 0..<assetCount {
                guard let path = try reader.readNullableUTF16BEString() else {
                    throw ThemeFileCodecError.invalid("资产 \(index) 路径为 null")
                }
                guard let assetData = try reader.readNullableByteArray() else {
                    throw ThemeFileCodecError.invalid("资产 \(index)('\(path)')数据为 null")
                }
                assets.append(ThemeAsset(path: path, data: assetData))
            }
        }
        // 尾部 4 零字节:解码容忍缺失,编码必须写出。

        return ThemeFile(
            language: language,
            keyMacroValue: keyMacroValue,
            keyMacro: keyMacro,
            layoutJSON: layoutJSON,
            assets: assets
        )
    }

    /// 扫描平衡的顶层 `{}`/`[]` 找 JSON 结尾下标(尊重字符串引号转义)。
    /// 返回最后一个有效字节的下标。
    private static func findJSONEnd(_ data: Data, from start: Int) throws -> Int {
        var index = start
        var depth = 0
        var inString = false
        var escaped = false

        while index < data.count {
            let byte = data[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index += 1
        }
        throw ThemeFileCodecError.invalid("布局 JSON 括号不平衡,找不到结尾")
    }

    // MARK: - Encoding

    /// 与 decode 互逆;布局 JSON 按调用方给定的文本原样写入
    /// (规范化 — 4 空格缩进/键字母序/字符串数值 — 由 ThemeBuilder 负责)。
    static func encode(_ theme: ThemeFile) -> Data {
        var out = Data()

        var header: [String: TaggedValue] = [:]
        // 字段顺序与官方参考文件一致(language, keyMacroValue, keyMacro)。
        header["language"] = .int32(theme.language)
        header["keyMacroValue"] = .byteArray(theme.keyMacroValue)
        header["keyMacro"] = theme.keyMacro.map { .byteArray($0) } ?? .nullByteArray
        writeTaggedMap(header, into: &out)

        let jsonBytes = Data(theme.layoutJSON.utf8)
        out.append(contentsOf: [0, 0, 0, 0])
        out.appendBigEndian(UInt32(jsonBytes.count + 1))

        out.append(jsonBytes)
        out.append(jsonTerminator)

        out.appendBigEndian(UInt32(theme.assets.count))
        for asset in theme.assets {
            writeUTF16BEString(asset.path, into: &out)
            out.appendBigEndian(UInt32(asset.data.count))
            out.append(asset.data)
        }

        // 必需的 4 零字节尾:缺失时 text 键失灵(真机确认)。
        out.append(contentsOf: [0, 0, 0, 0])
        return out
    }

    // MARK: - Qt QVariant 标签值编解码(§5.2, 与 cmd=13 载荷同源)

    /// QVariant 标签值。`.theme` header 只用到 int32/byteArray;
    /// 其余类型供 controlData(controlFlow 步骤)等嵌套结构解码使用。
    enum TaggedValue: Equatable {
        case bool(Bool)
        case int32(Int32)
        case double(Double)
        case string(String?)
        case byteArray(Data?)
        case map([String: TaggedValue])
        case list([TaggedValue])
    }

    private enum TaggedType {
        static let bool: UInt32 = 1
        static let int32: UInt32 = 2
        static let double: UInt32 = 6
        static let map: UInt32 = 8
        static let list: UInt32 = 9
        static let string: UInt32 = 10
        static let byteArray: UInt32 = 12
    }

    private static func writeTaggedMap(_ map: [String: TaggedValue], into out: inout Data) {
        out.appendBigEndian(UInt32(map.count))
        for (key, value) in map {
            writeUTF16BEString(key, into: &out)
            writeTaggedValue(value, into: &out)
        }
    }

    private static func writeTaggedValue(_ value: TaggedValue, into out: inout Data) {
        switch value {
        case .bool(let raw):
            out.appendBigEndian(TaggedType.bool)
            out.append(0)
            out.append(raw ? 1 : 0)
        case .int32(let raw):
            out.appendBigEndian(TaggedType.int32)
            out.append(0)
            out.appendBigEndian(UInt32(bitPattern: raw))
        case .double(let raw):
            out.appendBigEndian(TaggedType.double)
            out.append(0)
            out.appendBigEndian(raw.bitPattern)
        case .map(let raw):
            out.appendBigEndian(TaggedType.map)
            out.append(0)
            writeTaggedMap(raw, into: &out)
        case .list(let raw):
            out.appendBigEndian(TaggedType.list)
            out.append(0)
            out.appendBigEndian(UInt32(raw.count))
            for item in raw { writeTaggedValue(item, into: &out) }
        case .string(let raw):
            out.appendBigEndian(TaggedType.string)
            out.append(0)
            writeNullableUTF16BEString(raw, into: &out)
        case .byteArray(let raw):
            out.appendBigEndian(TaggedType.byteArray)
            out.append(0)
            writeNullableByteArray(raw, into: &out)
        }
    }

    private static func writeNullableUTF16BEString(_ value: String?, into out: inout Data) {
        guard let value else {
            out.appendBigEndian(nullLengthSentinel)
            return
        }
        writeUTF16BEString(value, into: &out)
    }

    private static func writeUTF16BEString(_ value: String, into out: inout Data) {
        let units = Array(value.utf16)
        out.appendBigEndian(UInt32(units.count * 2))
        for unit in units {
            out.append(UInt8(unit >> 8))
            out.append(UInt8(unit & 0xFF))
        }
    }

    private static func writeNullableByteArray(_ value: Data?, into out: inout Data) {
        guard let value else {
            out.appendBigEndian(nullLengthSentinel)
            return
        }
        out.appendBigEndian(UInt32(value.count))
        out.append(value)
    }

    private struct TaggedReader {
        let data: Data
        var offset = 0

        var remainingBytes: Int { data.count - offset }

        mutating func skip(_ count: Int) { offset += count }

        func peekByte() -> UInt8? {
            offset < data.count ? data[offset] : nil
        }

        mutating func readUInt32() throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw ThemeFileCodecError.truncated("u32 字段")
            }
            let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            return value
        }

        mutating func readNullableUTF16BEString() throws -> String? {
            let byteCount = try readUInt32()
            if byteCount == nullLengthSentinel { return nil }
            return try readUTF16BE(byteCount: Int(byteCount))
        }

        mutating func readNullableByteArray() throws -> Data? {
            let byteCount = try readUInt32()
            if byteCount == nullLengthSentinel { return nil }
            guard byteCount <= 64 * 1_024 * 1_024 else {
                throw ThemeFileCodecError.invalid("字节数组长度 \(byteCount) 不可信")
            }
            guard offset + Int(byteCount) <= data.count else {
                throw ThemeFileCodecError.truncated("字节数组数据")
            }
            let value = data.subdata(in: offset..<(offset + Int(byteCount)))
            offset += Int(byteCount)
            return value
        }

        mutating func readTaggedMap() throws -> [String: TaggedValue] {
            let count = try readUInt32()
            guard count <= 1_000 else {
                throw ThemeFileCodecError.invalid("map 条目数 \(count) 不可信")
            }
            var map: [String: TaggedValue] = [:]
            for _ in 0..<count {
                guard let key = try readNullableUTF16BEString() else {
                    throw ThemeFileCodecError.invalid("map 键为 null")
                }
                map[key] = try readTaggedValue()
            }
            return map
        }

        private mutating func readTaggedValue() throws -> TaggedValue {
            let typeID = try readUInt32()
            guard offset < data.count else {
                throw ThemeFileCodecError.truncated("isNull 标志")
            }
            let isNull = data[offset] != 0
            offset += 1
            if isNull { return .string(nil) }

            switch typeID {
            case TaggedType.bool:
                guard offset < data.count else { throw ThemeFileCodecError.truncated("bool 载荷") }
                defer { offset += 1 }
                return .bool(data[offset] != 0)
            case TaggedType.int32:
                return .int32(Int32(bitPattern: try readUInt32()))
            case TaggedType.double:
                guard offset + 8 <= data.count else { throw ThemeFileCodecError.truncated("double 载荷") }
                let bits = data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                offset += 8
                return .double(Double(bitPattern: bits))
            case TaggedType.map:
                return .map(try readTaggedMap())
            case TaggedType.list:
                let count = try readUInt32()
                guard count <= 10_000 else {
                    throw ThemeFileCodecError.invalid("list 条目数 \(count) 不可信")
                }
                var items: [TaggedValue] = []
                for _ in 0..<count { items.append(try readTaggedValue()) }
                return .list(items)
            case TaggedType.string:
                return .string(try readNullableUTF16BEString())
            case TaggedType.byteArray:
                guard let bytes = try readNullableByteArray() else { return .byteArray(nil) }
                return .byteArray(bytes)
            default:
                throw ThemeFileCodecError.invalid("未知标签类型 \(typeID)")
            }
        }

        private mutating func readUTF16BE(byteCount: Int) throws -> String {
            guard byteCount <= 1_024 * 1_024 else {
                throw ThemeFileCodecError.invalid("字符串长度 \(byteCount) 不可信")
            }
            guard byteCount.isMultiple(of: 2), byteCount <= data.count - offset else {
                throw ThemeFileCodecError.truncated("UTF-16BE 字符串数据")
            }
            var units: [UInt16] = []
            units.reserveCapacity(byteCount / 2)
            var index = offset
            while index < offset + byteCount {
                units.append((UInt16(data[index]) << 8) | UInt16(data[index + 1]))
                index += 2
            }
            offset += byteCount
            guard let value = String(bytes: units.flatMap {
                [UInt8($0 >> 8), UInt8($0 & 0xFF)]
            }, encoding: .utf16BigEndian) else {
                throw ThemeFileCodecError.invalid("UTF-16BE 解码失败")
            }
            return value
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

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
