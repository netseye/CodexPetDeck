import Foundation
import IOKit.hid

/// Talks to the physical Codex Micro-compatible HID function exposed by MK20.
///
/// ChatGPT/Codex opens the same HID normally.  CodexPetDeck only sends a private
/// `v.mk20.hid` command to the device-side bridge; the bridge emits the official
/// `v.oai.hid` notification back through the physical input endpoint.  No
/// ChatGPT process injection or virtual-HID entitlement is involved.
final class CodexMicroHIDTransport: @unchecked Sendable {
    static let vendorID = 0x303A
    static let productID = 0x8360
    static let usagePage = 0xFF00
    static let usage = 1

    var onConnectedChanged: ((Bool) -> Void)?
    var onHostHandshake: (() -> Void)?
    var onBridgeProbeResponse: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "codexpet.codexmicro.hid")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let reassembler = CodexMicroHIDFraming.Reassembler()
    private let bridgeProbeID = 9_913

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    func sendKey(_ key: String, pressed: Bool, agent: Int? = nil) {
        var params: [String: Any] = [
            "k": key,
            "act": pressed ? CodexMicroProtocol.Act.press.rawValue
                : CodexMicroProtocol.Act.release.rawValue,
        ]
        if let agent { params["ag"] = agent }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["method": "v.mk20.hid", "params": params],
            options: [.sortedKeys]
        ) else { return }
        let message = String(decoding: data, as: UTF8.self) + "\n"
        queue.async { [weak self] in self?.sendOnQueue(message) }
    }

    func probeBridge() {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "id": bridgeProbeID,
            "method": CodexMicroProtocol.Method.sysVersion,
        ], options: [.sortedKeys]) else { return }
        let message = String(decoding: data, as: UTF8.self) + "\n"
        queue.async { [weak self] in self?.sendOnQueue(message) }
    }

    private func startOnQueue() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, codexMicroDeviceAdded, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, codexMicroDeviceRemoved, context)
        // Register reports on the manager before it becomes active. macOS 26
        // asserts if a per-device report callback is registered from the device
        // matching callback after a dispatch-backed manager has been activated.
        IOHIDManagerRegisterInputReportCallback(manager, codexMicroInputReport, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            self.manager = nil
            onError?("无法打开 Codex Micro HID 管理器（0x\(String(result, radix: 16))）")
            return
        }
    }

    private func stopOnQueue() {
        disconnectCurrentDevice()
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    fileprivate func deviceAdded(_ candidate: IOHIDDevice) {
        guard device == nil else { return }
        let page = property(candidate, kIOHIDPrimaryUsagePageKey)?.intValue
        let usage = property(candidate, kIOHIDPrimaryUsageKey)?.intValue
        guard (page == nil || page == Self.usagePage),
              (usage == nil || usage == Self.usage) else { return }

        // IOHIDManagerOpen opens current and future matching devices. Keeping
        // ownership at manager level also allows Codex.app to open the HID.
        device = candidate
        onConnectedChanged?(true)
    }

    fileprivate func deviceRemoved(_ candidate: IOHIDDevice) {
        guard let device, device === candidate else { return }
        disconnectCurrentDevice()
    }

    fileprivate func receivedReport(
        result: IOReturn,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        length: CFIndex
    ) {
        guard result == kIOReturnSuccess, length > 0 else { return }
        var data = Data(bytes: report, count: length)
        if data.first != CodexMicroHIDFraming.reportID,
           reportID == UInt32(CodexMicroHIDFraming.reportID) {
            data.insert(CodexMicroHIDFraming.reportID, at: 0)
        }
        for message in reassembler.push(data) {
            guard let id = CodexMicroProtocol.parse(message)?.id else { continue }
            if id == bridgeProbeID {
                onBridgeProbeResponse?(message)
            } else {
                // All other response IDs belong to ChatGPT/Codex and prove its
                // desktop process has completed a physical-device RPC.
                onHostHandshake?()
            }
        }
    }

    private func sendOnQueue(_ message: String) {
        guard let device else {
            onError?("MK20 尚未枚举为 Codex Micro；请先安装设备端组件并重启 MK20")
            return
        }
        for report in CodexMicroHIDFraming.encode(message) {
            let result = report.withUnsafeBytes { raw -> IOReturn in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return kIOReturnBadArgument
                }
                return IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    CFIndex(CodexMicroHIDFraming.reportID),
                    bytes,
                    report.count
                )
            }
            guard result == kIOReturnSuccess else {
                onError?("Codex Micro HID 写入失败（0x\(String(result, radix: 16))）")
                return
            }
        }
    }

    private func disconnectCurrentDevice() {
        device = nil
        onConnectedChanged?(false)
    }

    private func property(_ device: IOHIDDevice, _ key: String) -> NSNumber? {
        IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber
    }
}

private func codexMicroDeviceAdded(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<CodexMicroHIDTransport>.fromOpaque(context)
        .takeUnretainedValue().deviceAdded(device)
}

private func codexMicroDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<CodexMicroHIDTransport>.fromOpaque(context)
        .takeUnretainedValue().deviceRemoved(device)
}

private func codexMicroInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context else { return }
    Unmanaged<CodexMicroHIDTransport>.fromOpaque(context)
        .takeUnretainedValue().receivedReport(
            result: result,
            reportID: reportID,
            report: report,
            length: reportLength
        )
}
