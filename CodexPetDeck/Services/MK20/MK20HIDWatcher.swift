import CoreGraphics
import Foundation
import IOKit.hid
import IOKit.hidsystem

/// 两枚 MK20 旋钮的六个独立物理输入。新版主题给它们分配与 20 个屏幕键
/// 不重叠的 HID usage，因此宿主能够准确区分按键与旋钮。
enum MK20EncoderControl: Int, CaseIterable, Hashable, Identifiable {
    case leftCounterClockwise
    case leftPress
    case leftClockwise
    case rightCounterClockwise
    case rightPress
    case rightClockwise

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .leftCounterClockwise: "左旋钮 ↶"
        case .leftPress: "左旋钮按压"
        case .leftClockwise: "左旋钮 ↷"
        case .rightCounterClockwise: "右旋钮 ↶"
        case .rightPress: "右旋钮按压"
        case .rightClockwise: "右旋钮 ↷"
        }
    }

    var shortTitle: String {
        switch self {
        case .leftCounterClockwise: "左↶"
        case .leftPress: "左按"
        case .leftClockwise: "左↷"
        case .rightCounterClockwise: "右↶"
        case .rightPress: "右按"
        case .rightClockwise: "右↷"
        }
    }

    var action: PetAction {
        switch self {
        case .leftCounterClockwise: .previousSession
        case .leftPress: .focusCodex
        case .leftClockwise: .nextSession
        case .rightCounterClockwise: .scrollUp
        case .rightPress: .stopTask
        case .rightClockwise: .scrollDown
        }
    }
}

/// MK20 按键通路: 直接监听 SYK 的物理 HID 键盘接口。
///
/// 真机在 macOS 中稳定枚举为 4250:426F、Usage Page 1 / Usage 6 的
/// `syk_keyboards`。直接读取 HID element，避免 CGEventTap 因签名、前台应用、
/// 辅助功能权限组合而创建失败；仍只需 macOS“输入监控”权限。
///
/// keycode 打包: (modifierBitmap << 8) | HIDUsage; LCtrl=1, LShift=2,
/// LAlt=4, LWin=8; Ctrl+Alt = 5。
final class MK20HIDWatcher: @unchecked Sendable {
    enum PermissionState: Equatable {
        case granted
        case denied
        case notDetermined
    }

    static let vendorID = 0x4250
    static let productID = 0x426F
    static let keyboardUsagePage = 0x01
    static let keyboardUsage = 0x06

    var onKey: ((_ row: Int, _ col: Int, _ pressed: Bool) -> Void)?
    var onEncoder: ((_ control: MK20EncoderControl, _ pressed: Bool) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private(set) var tapActive = false

    private var manager: IOHIDManager?
    private var downModifiers: Set<UInt32> = []
    private var downKeys: Set<UInt32> = []
    private var keyDownTimes: [UInt32: TimeInterval] = [:]
    private let lock = NSLock()

    /// A theme reload can interrupt the keyboard report that releases a key.
    /// Do not let one lost release permanently disable that key.
    private static let staleKeyDownInterval: TimeInterval = 0.75

    static func permissionState() -> PermissionState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        default:
            return .notDetermined
        }
    }

    @discardableResult
    static func requestPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: Self.keyboardUsagePage,
            kIOHIDPrimaryUsageKey as String: Self.keyboardUsage,
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(
            manager,
            mk20PhysicalInputValue,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            mk20PhysicalDeviceMatched,
            Unmanaged.passUnretained(self).toOpaque()
        )
        // 使用 RunLoop 调度，避免 dispatch 版本要求“必须等 cancel handler 后
        // 才能释放 IOHIDManagerRef”的特殊生命周期。Swift ARC 会在 start()
        // 返回时平衡局部引用，直接使用 dispatch 版本会被 IOKit 判为
        // Invalid dispatch state 并主动终止进程。
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            onDiagnostic?(
                "⚠ MK20 原始 HID 打开失败（IOReturn=0x" +
                String(UInt32(bitPattern: result), radix: 16, uppercase: true) + "）"
            )
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            self.manager = nil
            tapActive = false
            return
        }
        tapActive = true
        onDiagnostic?("MK20 原始 HID 监听已启动，等待 4250:426F 键盘接口")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        downModifiers.removeAll()
        downKeys.removeAll()
        keyDownTimes.removeAll()
        tapActive = false
    }

    /// Theme reloads keep the USB HID interface alive, so IOHIDManager does not
    /// receive a disconnect callback. Clear report-local state explicitly to
    /// recover when the reload swallowed a key-up report.
    func resetPressedState() {
        downModifiers.removeAll()
        downKeys.removeAll()
        keyDownTimes.removeAll()
        onDiagnostic?("MK20 HID 按键状态已复位")
    }

    fileprivate func received(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == 0x07 else { return }
        let usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) != 0

        if Self.modifierUsages.contains(usage) {
            if pressed { downModifiers.insert(usage) }
            else { downModifiers.remove(usage) }
            return
        }

        let coordinate = PetKeyCodes.hidLayout[usage]
        let encoderControl = PetKeyCodes.encoderHIDLayout[usage]
        guard coordinate != nil || encoderControl != nil else { return }
        if pressed {
            let now = ProcessInfo.processInfo.systemUptime
            if downKeys.contains(usage),
               let downAt = keyDownTimes[usage],
               now - downAt < Self.staleKeyDownInterval {
                return
            }
            downKeys.insert(usage)
            keyDownTimes[usage] = now
            // 同一 HID report 中 element callback 的顺序不作假设；排到主队列尾部，
            // 等 Ctrl/Alt element 都更新后再判断组合键。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let controlDown = !self.downModifiers.isDisjoint(with: Self.controlUsages)
                let optionDown = !self.downModifiers.isDisjoint(with: Self.optionUsages)
                self.onDiagnostic?(
                    "MK20 原始\(encoderControl == nil ? "键" : "旋钮") " +
                    "usage=0x\(String(usage, radix: 16, uppercase: true)) " +
                    "ctrl=\(controlDown ? 1 : 0) option=\(optionDown ? 1 : 0)"
                )
                // Stock MK20 firmware uses a standalone left-Shift modifier
                // for K18. It intentionally has no Ctrl/Alt wrapper.
                if usage == PetKeyCodes.officialK18Usage, let coordinate {
                    self.onKey?(coordinate.row, coordinate.col, true)
                    return
                }
                guard controlDown, optionDown else { return }
                if let coordinate {
                    self.onKey?(coordinate.row, coordinate.col, true)
                } else if let encoderControl {
                    self.onEncoder?(encoderControl, true)
                }
            }
        } else if downKeys.remove(usage) != nil {
            keyDownTimes.removeValue(forKey: usage)
            if let coordinate {
                onKey?(coordinate.row, coordinate.col, false)
            } else if let encoderControl {
                onEncoder?(encoderControl, false)
            }
        }
    }

    private static let controlUsages: Set<UInt32> = [0xE0, 0xE4]
    private static let optionUsages: Set<UInt32> = [0xE2, 0xE6]
    private static let modifierUsages = controlUsages.union(optionUsages)

    fileprivate func deviceMatched() {
        onDiagnostic?("MK20 物理键盘 HID 已绑定（4250:426F · Usage 1:6）")
    }

    deinit {
        stop()
    }
}

private func mk20PhysicalDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<MK20HIDWatcher>.fromOpaque(context)
        .takeUnretainedValue().deviceMatched()
}

private func mk20PhysicalInputValue(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<MK20HIDWatcher>.fromOpaque(context)
        .takeUnretainedValue().received(value)
}

/// CodexPet 键位表(单一事实源): 主题生成与 app 反查都读它。
enum PetKeyCodes {
    static let deckModifier: UInt64 = 5  // Ctrl(1) | Alt(4)
    static let officialK18Usage: UInt32 = 0xE1 // Left Shift, stock theme K18

    struct KeySlot {
        let row: Int
        let col: Int
        let hidUsage: UInt32
    }

    struct EncoderSlot {
        let control: MK20EncoderControl
        let hidUsage: UInt32
    }

    static let slots: [KeySlot] = [
        // row0: 会话 1-6 = Ctrl+Alt+Q/W/E/R/T
        KeySlot(row: 0, col: 0, hidUsage: 0x14), // Q
        KeySlot(row: 0, col: 1, hidUsage: 0x1A), // W
        KeySlot(row: 0, col: 2, hidUsage: 0x08), // E
        KeySlot(row: 0, col: 3, hidUsage: 0x15), // R
        KeySlot(row: 0, col: 4, hidUsage: 0x17), // T
        // row1: 会话6 + 动作 = Ctrl+Alt+A/S/D/F/G
        KeySlot(row: 1, col: 0, hidUsage: 0x04), // A
        KeySlot(row: 1, col: 1, hidUsage: 0x16), // S
        KeySlot(row: 1, col: 2, hidUsage: 0x07), // D
        KeySlot(row: 1, col: 3, hidUsage: 0x09), // F
        KeySlot(row: 1, col: 4, hidUsage: 0x0A), // G
        // row2: ACT10 语音 = Ctrl+Alt+Z
        KeySlot(row: 2, col: 0, hidUsage: 0x1D), // Z
        KeySlot(row: 2, col: 1, hidUsage: 0x1B), // X
        KeySlot(row: 2, col: 2, hidUsage: 0x06), // C
        KeySlot(row: 2, col: 3, hidUsage: 0x19), // V
        KeySlot(row: 2, col: 4, hidUsage: 0x05), // B
        // row3: K18 uses the stock theme's standalone Left Shift lane; the
        // remaining keys retain Ctrl+Alt wrappers.
        KeySlot(row: 3, col: 0, hidUsage: 0x18), // U
        KeySlot(row: 3, col: 1, hidUsage: 0x0C), // I
        KeySlot(row: 3, col: 2, hidUsage: officialK18Usage), // stock K18 / L Shift
        KeySlot(row: 3, col: 3, hidUsage: 0x13), // P
        KeySlot(row: 3, col: 4, hidUsage: 0x0F), // L
    ]

    /// Ctrl+Alt+1...6，避开 20 个屏幕键使用的字母 usage。
    static let encoderSlots: [EncoderSlot] = [
        EncoderSlot(control: .leftCounterClockwise, hidUsage: 0x1E),
        EncoderSlot(control: .leftPress, hidUsage: 0x1F),
        EncoderSlot(control: .leftClockwise, hidUsage: 0x20),
        EncoderSlot(control: .rightCounterClockwise, hidUsage: 0x21),
        EncoderSlot(control: .rightPress, hidUsage: 0x22),
        EncoderSlot(control: .rightClockwise, hidUsage: 0x23),
    ]

    /// 主题 keyboard keycode(打包 (modifiers<<8)|usage)。主题生成与 app
    /// 反查共用此表：SYK 转发组合键，CGEventTap 再按同一坐标表吃掉。
    static func themeKeycode(index: Int) -> Int32 {
        guard slots.indices.contains(index) else { return 0 }
        let packed = (deckModifier << 8) | UInt64(slots[index].hidUsage)
        return Int32(bitPattern: UInt32(truncatingIfNeeded: packed))
    }

    static func themeKeycode(for action: PetAction) -> Int32 {
        guard let index = CodexPetThemeBuilder.physicalLayout().firstIndex(where: {
            $0.role == .action(action)
        }) else { return 0 }
        return themeKeycode(index: index)
    }

    static func encoderThemeKeycode(for control: MK20EncoderControl) -> Int32 {
        guard let slot = encoderSlots.first(where: { $0.control == control }) else { return 0 }
        let packed = (deckModifier << 8) | UInt64(slot.hidUsage)
        return Int32(bitPattern: UInt32(truncatingIfNeeded: packed))
    }

    /// HID usage → CG keycode(ANSI 布局): QWERT/ASDFG/Z。
    static var cgLayout: [Int: (row: Int, col: Int)] {
        let usageToCG: [UInt32: Int] = [
            0x14: 12, 0x1A: 13, 0x08: 14, 0x15: 15, 0x17: 17,  // QWERT
            0x04: 0, 0x16: 1, 0x07: 2, 0x09: 3, 0x0A: 5,        // ASDFG
            0x1D: 6,                                               // Z
            0x1B: 7, 0x06: 8, 0x19: 9, 0x05: 11,                  // XCVB
            0x18: 32, 0x0C: 34, 0x13: 35, 0x0F: 37,              // U I P L
        ]
        var map: [Int: (Int, Int)] = [:]
        for slot in slots {
            if let cg = usageToCG[slot.hidUsage] {
                map[cg] = (slot.row, slot.col)
            }
        }
        return map
    }

    /// HID Usage → MK20 键格。直接物理 HID 监听与主题生成共用同一事实源。
    static var hidLayout: [UInt32: (row: Int, col: Int)] {
        Dictionary(uniqueKeysWithValues: slots.map { ($0.hidUsage, ($0.row, $0.col)) })
    }

    static var encoderHIDLayout: [UInt32: MK20EncoderControl] {
        Dictionary(uniqueKeysWithValues: encoderSlots.map { ($0.hidUsage, $0.control) })
    }

    static func matches(cgKeycode: Int, flags: CGEventFlags) -> Bool {
        guard flags.contains(.maskControl), flags.contains(.maskAlternate) else { return false }
        return cgLayout[cgKeycode] != nil
    }
}
