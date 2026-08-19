import Foundation

/// Codex Micro JSON-RPC names shared by the physical HID transport and tests.
enum CodexMicroProtocol {
    enum Method {
        static let deviceStatus = "device.status"
        static let sysVersion = "sys.version"
        static let lightsPreview = "lights.preview"
        static let rgbConfig = "v.oai.rgbcfg"
        static let threadsLighting = "v.oai.thstatus"
    }

    enum Notify {
        static let hid = "v.oai.hid"
        static let radial = "v.oai.rad"
    }

    enum Keys {
        static let agent = ["AG00", "AG01", "AG02", "AG03", "AG04", "AG05"]
        static let action = ["ACT06", "ACT07", "ACT08", "ACT09", "ACT10", "ACT12"]
        static let encoder = "ENC"
        static let encoderCounterClockwise = "ENC_CC"
        static let encoderClockwise = "ENC_CW"
    }

    enum Act: Int {
        case release = 0
        case press = 1
        case hold = 2
    }

    static func response(id: Int, result: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["id": id, "result": result])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func notification(method: String, params: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["method": method, "params": params]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func parse(_ line: String) -> (id: Int?, method: String?, params: Any?)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let id: Int?
        if let value = object["id"] as? Int { id = value }
        else if let value = object["i"] as? Int { id = value }
        else if let value = (object["id"] ?? object["i"]) as? String { id = Int(value) }
        else { id = nil }
        return (
            id,
            (object["method"] ?? object["m"]) as? String,
            object["params"] ?? object["p"]
        )
    }
}

/// Small protocol oracle used by unit tests. Production RPC responses are
/// generated on MK20 by DeviceSupport/codex-micro-bridge.c.
final class CodexMicroEmulator {
    var onSend: ((String) -> Void)?
    var onRequest: ((Int?, String?, Any?) -> Void)?

    func handle(_ line: String) {
        guard let request = CodexMicroProtocol.parse(line), let id = request.id else { return }
        onRequest?(id, request.method, request.params)
        switch request.method {
        case CodexMicroProtocol.Method.deviceStatus:
            sendResponse(id: id, result: [
                "version": "1.0.0",
                "profile_index": 0,
                "layer_index": 0,
                "battery": 100,
                "is_charging": true,
            ])
        case CodexMicroProtocol.Method.sysVersion:
            sendResponse(id: id, result: ["version": "1.0.0"])
        case CodexMicroProtocol.Method.rgbConfig,
             CodexMicroProtocol.Method.threadsLighting,
             CodexMicroProtocol.Method.lightsPreview:
            sendResponse(id: id, result: true)
        default:
            sendResponse(id: id, result: true)
        }
    }

    func tapAgent(_ slot: Int) {
        guard CodexMicroProtocol.Keys.agent.indices.contains(slot) else { return }
        let key = CodexMicroProtocol.Keys.agent[slot]
        sendKey(key, act: .press, agent: slot)
        sendKey(key, act: .release, agent: slot)
    }

    func tapAction(_ key: String) {
        sendKey(key, act: .press)
        sendKey(key, act: .release)
    }

    private func sendKey(_ key: String, act: CodexMicroProtocol.Act, agent: Int? = nil) {
        var params: [String: Any] = ["k": key, "act": act.rawValue]
        if let agent { params["ag"] = agent }
        onSend?(CodexMicroProtocol.notification(method: CodexMicroProtocol.Notify.hid, params: params))
    }

    private func sendResponse(id: Int, result: Any) {
        onSend?(CodexMicroProtocol.response(id: id, result: result))
    }
}

/// Codex Micro 64-byte report: report ID 6 + channel + length + up to 61 UTF-8 bytes.
enum CodexMicroHIDFraming {
    static let reportID: UInt8 = 0x06
    static let reportSize = 64
    static let maximumPayload = 61
    static let rpcChannel: UInt8 = 2

    static func encode(_ message: String) -> [Data] {
        let bytes = Array(message.utf8)
        var reports: [Data] = []
        var offset = 0
        repeat {
            let count = min(maximumPayload, bytes.count - offset)
            var report = Data(repeating: 0, count: reportSize)
            report[0] = reportID
            report[1] = rpcChannel
            report[2] = UInt8(count)
            if count > 0 {
                report.replaceSubrange(3..<(3 + count), with: bytes[offset..<(offset + count)])
            }
            reports.append(report)
            offset += count
        } while offset < bytes.count
        return reports
    }

    final class Reassembler {
        private var rpcBuffer = ""

        func push(_ rawReport: Data) -> [String] {
            let report = rawReport.first == reportID ? Data(rawReport.dropFirst()) : rawReport
            guard report.count >= 2, report[0] == rpcChannel else { return [] }
            let length = min(Int(report[1]), max(0, report.count - 2))
            rpcBuffer += String(data: report.subdata(in: 2..<(2 + length)), encoding: .utf8) ?? ""
            let result = Self.extractJSONObjects(rpcBuffer)
            rpcBuffer = result.rest
            return result.objects
        }

        private static func extractJSONObjects(_ buffer: String) -> (objects: [String], rest: String) {
            let characters = Array(buffer)
            var objects: [String] = []
            var depth = 0
            var start: Int?
            var consumed = 0
            var inString = false
            var escaped = false

            for (index, character) in characters.enumerated() {
                if inString {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inString = false }
                    continue
                }
                if character == "\"" { inString = true }
                else if character == "{" {
                    if depth == 0 { start = index }
                    depth += 1
                } else if character == "}", depth > 0 {
                    depth -= 1
                    if depth == 0, let start {
                        objects.append(String(characters[start...index]))
                        consumed = index + 1
                    }
                }
            }
            if depth > 0, let start { return (objects, String(characters[start...])) }
            return (objects, String(characters.dropFirst(consumed)))
        }
    }
}
