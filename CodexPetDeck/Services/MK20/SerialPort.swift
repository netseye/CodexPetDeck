import Darwin
import Foundation
import IOKit
import IOKit.hid

enum SerialPortError: LocalizedError {
    case cannotOpen(String)
    case cannotConfigure(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path): "无法打开串口 \(path)"
        case .cannotConfigure(let path): "无法配置串口 \(path)"
        case .writeFailed: "串口写入失败"
        }
    }
}

final class SerialPort: @unchecked Sendable {
    static let rawUSBPath = "usb://mk20-codex-bulk"

    var onData: ((Data) -> Void)?
    var onBytesWritten: ((Int) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private let readQueue = DispatchQueue(label: "com.screenkey.serial.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.screenkey.serial.write", qos: .userInitiated)
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var rawManager: IOHIDManager?
    private var rawDevice: IOHIDDevice?

    var isOpen: Bool { currentDescriptor() >= 0 || currentRawDevice() != nil }

    static func availablePorts() -> [String] {
        let directory = "/dev"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var ports = entries
            // macOS exposes every serial device twice. `cu.*` is the callout
            // endpoint for an app that initiates a connection; `tty.*` is the
            // dial-in endpoint and can open successfully while responses remain
            // queued for the callout side.
            .filter { $0.hasPrefix("cu.") }
            .filter { !$0.contains("Bluetooth-Incoming-Port") }
            .map { "\(directory)/\($0)" }
            // Stock MK20 uses a numeric suffix. The native-gadget recovery path
            // may temporarily use MK20_CODEX_001; keep both while excluding the
            // Android phone serial-number style port (for example R5CY93DT5XN2).
            .filter { isMK20Candidate($0) }
            .sorted { lhs, rhs in
                let lhsUSB = lhs.localizedCaseInsensitiveContains("usb")
                let rhsUSB = rhs.localizedCaseInsensitiveContains("usb")
                return lhsUSB == rhsUSB ? lhs < rhs : lhsUSB
            }
        if rawUSBAvailable() {
            ports.insert(rawUSBPath, at: 0)
        }
        return ports
    }

    /// usbmodem 后缀是纯数字(MK20 CDC 口)还是字母 SN(手机)。
    private static func isMK20Candidate(_ port: String) -> Bool {
        if port.localizedCaseInsensitiveContains("MK20_CODEX") { return true }
        guard let range = port.range(of: "cu.usbmodem") else { return true }
        let suffix = String(port[range.upperBound...])
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    func open(path: String) throws {
        close()

        if path == Self.rawUSBPath {
            try openRawUSB()
            return
        }

        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialPortError.cannotOpen(path) }

        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            Darwin.close(fd)
            throw SerialPortError.cannotConfigure(path)
        }

        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CSIZE)
        options.c_cflag |= tcflag_t(CS8)
        options.c_cflag &= ~tcflag_t(CRTSCTS)

        guard
            cfsetspeed(&options, speed_t(B115200)) == 0,
            tcsetattr(fd, TCSANOW, &options) == 0
        else {
            Darwin.close(fd)
            throw SerialPortError.cannotConfigure(path)
        }

        // QSerialPort opens ports exclusively. Matching that behavior prevents
        // another app or a second debug run from consuming device responses.
        guard ioctl(fd, TIOCEXCL) == 0 else {
            Darwin.close(fd)
            throw SerialPortError.cannotOpen(path)
        }

        // Keep the descriptor non-blocking. A USB CDC write can otherwise hold the
        // same execution context for a long time while the device is already
        // trying to send its response.
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        stateLock.lock()
        descriptor = fd
        stateLock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in self?.readAvailableData() }
        source.setCancelHandler { Darwin.close(fd) }
        stateLock.lock()
        readSource = source
        stateLock.unlock()
        source.resume()
    }

    func close() {
        stateLock.lock()
        let source = readSource
        let manager = rawManager
        readSource = nil
        descriptor = -1
        rawManager = nil
        rawDevice = nil
        stateLock.unlock()
        source?.cancel()
        if let manager {
            closeRawManagerOnMainRunLoop(manager)
        }
    }

    @discardableResult
    func setDataTerminalReady(_ enabled: Bool) -> Bool {
        let descriptor = currentDescriptor()
        guard descriptor >= 0 else { return currentRawDevice() != nil }
        return ioctl(descriptor, enabled ? TIOCSDTR : TIOCCDTR) == 0
    }

    @discardableResult
    func setRequestToSend(_ enabled: Bool) -> Bool {
        let descriptor = currentDescriptor()
        guard descriptor >= 0 else { return currentRawDevice() != nil }
        var signal = Int32(TIOCM_RTS)
        return ioctl(descriptor, enabled ? TIOCMBIS : TIOCMBIC, &signal) == 0
    }

    func pinoutSignals() -> Int32? {
        let descriptor = currentDescriptor()
        guard descriptor >= 0 else { return nil }
        var signals: Int32 = 0
        guard ioctl(descriptor, TIOCMGET, &signals) == 0 else { return nil }
        return signals
    }

    func write(_ data: Data, completion: ((Result<Int, Error>) -> Void)? = nil) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            let descriptor = self.currentDescriptor()
            if descriptor < 0 {
                self.writeRawUSB(data, completion: completion)
                return
            }

            var bytesWritten = 0
            let didWriteAll = data.withUnsafeBytes { rawBuffer -> Bool in
                guard let baseAddress = rawBuffer.baseAddress else { return true }
                while bytesWritten < data.count {
                    guard self.currentDescriptor() == descriptor else { return false }
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: bytesWritten),
                        data.count - bytesWritten
                    )

                    if count > 0 {
                        bytesWritten += count
                        continue
                    }

                    if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                        guard self.waitUntilWritable(descriptor) else { return false }
                        continue
                    }

                    if errno == EINTR { continue }
                    return false
                }
                return true
            }

            if didWriteAll {
                self.onBytesWritten?(bytesWritten)
                completion?(.success(bytesWritten))
            } else {
                completion?(.failure(SerialPortError.writeFailed))
                self.onDisconnect?(SerialPortError.writeFailed)
                self.close()
            }
        }
    }

    private func readAvailableData() {
        let descriptor = currentDescriptor()
        guard descriptor >= 0 else { return }

        while true {
            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.read(descriptor, &bytes, bytes.count)

            if count > 0 {
                onData?(Data(bytes.prefix(count)))
                continue
            }

            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }

            onDisconnect?(nil)
            close()
            return
        }
    }

    private func currentDescriptor() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return descriptor
    }

    private static var rawHIDMatchingDictionary: CFDictionary {
        [
            kIOHIDVendorIDKey as String: 0x303A,
            kIOHIDProductIDKey as String: 0x8360,
            kIOHIDPrimaryUsagePageKey as String: 0xFF00,
            kIOHIDPrimaryUsageKey as String: 1,
        ] as CFDictionary
    }

    private static func rawUSBAvailable() -> Bool {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        IOHIDManagerSetDeviceMatching(manager, rawHIDMatchingDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return false
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return false
        }
        return !devices.isEmpty
    }

    private func openRawUSB() throws {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        IOHIDManagerSetDeviceMatching(manager, Self.rawHIDMatchingDictionary)
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            serialRawHIDDeviceRemoved,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerRegisterInputReportCallback(
            manager,
            serialRawHIDInputReport,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            throw SerialPortError.cannotOpen(Self.rawUSBPath)
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw SerialPortError.cannotOpen(Self.rawUSBPath)
        }

        stateLock.lock()
        rawManager = manager
        rawDevice = device
        stateLock.unlock()
    }

    fileprivate func receivedRawHIDReport(
        result: IOReturn,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        length: CFIndex
    ) {
        guard result == kIOReturnSuccess, length > 0 else { return }
        var data = Data(bytes: report, count: length)
        if data.first != 0x06, reportID == 0x06 {
            data.insert(0x06, at: 0)
        }
        let body = data.first == 0x06 ? Data(data.dropFirst()) : data
        guard body.count >= 2, body[0] == 0x03 else { return }
        let payloadLength = min(Int(body[1]), max(0, body.count - 2))
        guard payloadLength > 0 else { return }
        onData?(body.subdata(in: 2..<(2 + payloadLength)))
    }

    fileprivate func rawHIDDeviceRemoved(_ candidate: IOHIDDevice) {
        // IOHIDLib calls this while __IOHIDManagerDeviceRemoved still owns an
        // internal unfair lock. Closing or unscheduling the same manager from
        // inside this callback corrupts that lock state on macOS 26 and aborts
        // the process after the callback returns. Detach the device now so no
        // more writes can use it, then notify/close on the next main-loop turn.
        stateLock.lock()
        guard let current = rawDevice, current === candidate else {
            stateLock.unlock()
            return
        }
        rawDevice = nil
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDisconnect?(nil)
            self.close()
        }
    }

    private func writeRawUSB(
        _ data: Data,
        completion: ((Result<Int, Error>) -> Void)?
    ) {
        guard let device = currentRawDevice() else {
            completion?(.failure(SerialPortError.writeFailed))
            return
        }
        var offset = 0
        while offset < data.count {
            let count = min(61, data.count - offset)
            var report = Data(repeating: 0, count: 64)
            report[0] = 0x06
            report[1] = 0x03
            report[2] = UInt8(count)
            report.replaceSubrange(3..<(3 + count), with: data[offset..<(offset + count)])
            let result = report.withUnsafeBytes { raw -> IOReturn in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return kIOReturnBadArgument
                }
                return IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    0x06,
                    bytes,
                    report.count
                )
            }
            guard result == kIOReturnSuccess else {
                completion?(.failure(SerialPortError.writeFailed))
                onDisconnect?(SerialPortError.writeFailed)
                close()
                return
            }
            offset += count
            // The MK20 kernel function keeps at most 32 host reports while
            // the userspace bridge drains one report per poll iteration.
            // IOHID can otherwise enqueue a whole file burst fast enough to
            // discard the oldest reports silently, which leaves V2 waiting
            // forever for a FILE_END CRC that can never match.
            usleep(4_000)
        }
        onBytesWritten?(data.count)
        completion?(.success(data.count))
    }

    private func currentRawDevice() -> IOHIDDevice? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return rawDevice
    }

    private func closeRawManagerOnMainRunLoop(_ manager: IOHIDManager) {
        let cleanup = {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.async(execute: cleanup)
        }
    }

    private func waitUntilWritable(_ descriptor: Int32) -> Bool {
        var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        while currentDescriptor() == descriptor {
            let result = Darwin.poll(&item, 1, 250)
            if result > 0 {
                return (item.revents & Int16(POLLOUT)) != 0
            }
            if result < 0, errno != EINTR { return false }
        }
        return false
    }

    deinit {
        close()
    }
}

private func serialRawHIDInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context else { return }
    Unmanaged<SerialPort>.fromOpaque(context)
        .takeUnretainedValue().receivedRawHIDReport(
            result: result,
            reportID: reportID,
            report: report,
            length: reportLength
        )
}

private func serialRawHIDDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<SerialPort>.fromOpaque(context)
        .takeUnretainedValue().rawHIDDeviceRemoved(device)
}
