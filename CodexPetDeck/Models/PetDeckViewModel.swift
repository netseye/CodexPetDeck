import AppKit
import ApplicationServices
import Combine
import Foundation

/// CodexPetDeck 主状态机: Codex 会话 tail → 副屏实时推送 + 键帽主题。
///
/// 数据流(P4 参考项目宿主职责的 MK20 移植):
///
///   ~/.codex/sessions/*.jsonl ──CodexTailWatcher──▶ CodexTailEvent
///        │                                           │
///        │ state_5.sqlite 累计 token                    ├─▶ 消息中心(UI)
///        └───────────────────────────────────────────▶ ├─▶ 副屏五行(cmd=1, 0.5s 级)
///                                                      └─▶ 会话槽状态(键帽主题, 低频)
///
/// 副屏与主题固定走原厂 CDC，按键由 MK20HIDWatcher 读取独立的物理 HID。
/// Codex 动作通过深链、公开快捷键与辅助功能执行，不修改或注入 Codex 进程。
/// 自定义 303A:8360 gadget 已停用；仅保留从旧实验模式恢复 CDC 的逃生路径。
enum MK20USBPolicy {
    static let customGadgetInstallEnabled = false
    static let stableModeLabel = "原厂 CDC + 物理 HID"
}

/// MK20 的旋钮固件会在一个机械档位附近产生一小簇键盘脉冲。左旋钮负责
/// 会话选择，使用较短窗口；右旋钮实测会产生约两秒的滚动脉冲尾巴，使用
/// 独立的手势锁，避免一格滚动多页。
struct EncoderPulseGate {
    private enum Channel: Hashable {
        case left
        case right
    }

    let leftMinimumInterval: TimeInterval
    let rightMinimumInterval: TimeInterval
    private var lastAccepted: [Channel: TimeInterval] = [:]

    init(leftMinimumInterval: TimeInterval = 0.65, rightMinimumInterval: TimeInterval = 2.5) {
        self.leftMinimumInterval = leftMinimumInterval
        self.rightMinimumInterval = rightMinimumInterval
    }

    init(minimumInterval: TimeInterval) {
        leftMinimumInterval = minimumInterval
        rightMinimumInterval = minimumInterval
    }

    mutating func shouldAccept(_ action: PetAction, at timestamp: TimeInterval) -> Bool {
        let channel: Channel?
        switch action {
        case .previousSession, .nextSession:
            channel = .left
        case .scrollUp, .scrollDown:
            channel = .right
        default:
            channel = nil
        }
        guard let channel else { return true }
        let minimumInterval = channel == .left
            ? leftMinimumInterval
            : rightMinimumInterval
        if let previous = lastAccepted[channel], timestamp - previous < minimumInterval {
            return false
        }
        lastAccepted[channel] = timestamp
        return true
    }
}

/// 自检只保存硬件覆盖情况，不持有任何桌面控制能力。ViewModel 在记录输入后
/// 立即返回，因此自检期间不会切换会话、滚动、审批或停止任务。
struct HardwareSelfTestState: Equatable {
    private(set) var isEnabled = false
    private(set) var keyPressCounts = Array(repeating: 0, count: 20)
    private(set) var encoderCounts: [MK20EncoderControl: Int] = Dictionary(
        uniqueKeysWithValues: MK20EncoderControl.allCases.map { ($0, 0) }
    )
    private(set) var lastEvent = "尚未检测到输入"

    mutating func start() {
        isEnabled = true
        reset()
    }

    mutating func stop() {
        isEnabled = false
    }

    mutating func reset() {
        keyPressCounts = Array(repeating: 0, count: 20)
        encoderCounts = Dictionary(
            uniqueKeysWithValues: MK20EncoderControl.allCases.map { ($0, 0) }
        )
        lastEvent = "尚未检测到输入"
    }

    mutating func recordKey(row: Int, col: Int, role: PetKeyRole) {
        let index = row * 5 + col
        guard keyPressCounts.indices.contains(index) else { return }
        keyPressCounts[index] += 1
        lastEvent = "K\(index + 1) · \(role.title)"
    }

    mutating func recordEncoder(_ control: MK20EncoderControl) {
        encoderCounts[control, default: 0] += 1
        lastEvent = control.title
    }

    func keyCount(row: Int, col: Int) -> Int {
        let index = row * 5 + col
        return keyPressCounts.indices.contains(index) ? keyPressCounts[index] : 0
    }

    func encoderCount(_ control: MK20EncoderControl) -> Int {
        encoderCounts[control, default: 0]
    }

    var testedKeyCount: Int { keyPressCounts.filter { $0 > 0 }.count }
    var testedEncoderCount: Int { encoderCounts.values.filter { $0 > 0 }.count }
    var testedComponentCount: Int { testedKeyCount + testedEncoderCount }
    var totalPressCount: Int { keyPressCounts.reduce(0, +) + encoderCounts.values.reduce(0, +) }
    var coveragePercent: Int { testedComponentCount * 100 / 26 }
}

@MainActor
final class PetDeckViewModel: ObservableObject {
    // MARK: - 发布状态

    @Published private(set) var sessions: [CodexSessionRef] = []
    @Published private(set) var messages: [CodexTailEvent] = []
    @Published private(set) var slotStates: [PetSlotState] = Array(repeating: .idle, count: 6)
    @Published private(set) var slotProjects: [String] = Array(repeating: "", count: 6)
    @Published private(set) var latestUsage: CodexTailEvent?
    @Published private(set) var bubbleText = "等待事件…"
    @Published private(set) var selectedSessionIndex = 0
    @Published private(set) var mk20Connected = false
    @Published private(set) var mk20Connecting = false
    @Published private(set) var connectionStatus = "等待 MK20"
    @Published private(set) var deviceSummary = "尚未识别设备"
    @Published private(set) var hidCaptureActive = false
    @Published private(set) var inputMonitoringPermission: MK20HIDWatcher.PermissionState = .notDetermined
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var nativeMicroConnected = false
    @Published private(set) var microHostConnected = false
    @Published private(set) var tailRunning = false
    @Published private(set) var eventLog: [String] = []
    @Published private(set) var isDeployingTheme = false
    @Published private(set) var themeUploadProgress = 0.0
    @Published private(set) var isInstallingNativeMicro = false
    @Published private(set) var nativeInstallProgress = 0.0
    @Published private(set) var nativeInstallNeedsRestart = false
    @Published private(set) var hardwareSelfTest = HardwareSelfTestState()
    @Published var completionSoundEnabled = true
    @Published var presentedError: PresentedError?

    // MARK: - 组件

    let tailWatcher: CodexTailWatcher
    private let stateStore: CodexStateStore
    private let serialPort = SerialPort()
    private let v2Encoder = V2PacketEncoder()
    private var v2Parser = V2PacketParser()
    private let hidWatcher = MK20HIDWatcher()
    private let microHID = CodexMicroHIDTransport()
    private let codexDesktop = CodexDesktopController()
    private var requestedSystemData: Set<String> = []
    private var pushTimer: Timer?
    private var connectionState: ConnectionState = .disconnected
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var autoDeployTask: Task<Void, Never>?
    private var stateThemeRefreshTask: Task<Void, Never>?
    private var uploadTimeoutTask: Task<Void, Never>?
    private var preferredPort = ""
    private var shouldAutoReconnect = true
    private var reconnectAttempt = 0
    private var slotLastActivity: [Date] = Array(repeating: .distantPast, count: 6)
    private var lastPushSignature = ""
    private var bubbleTime = "--:--"
    private var bubbleKind = "等待"
    private var permissionObserver: AnyCancellable?
    private var completionAttentionSlots: Set<Int> = []
    private var encoderPulseGate = EncoderPulseGate()
    private var lastHIDInputAt: TimeInterval = -.infinity
    private var pendingK18NeighborColumn: Int?
    private var pendingK18NeighborTask: Task<Void, Never>?
    private var lastK18ActivationAt: TimeInterval = -.infinity
    private let completionSound = NSSound(named: NSSound.Name("Glass"))
    private let installedThemeRevisionKey = "installedCodexPetThemeRevision"
    private let k18ChordWindow: Duration = .milliseconds(70)
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }

    struct PresentedError: Identifiable {
        let id = UUID()
        let message: String
    }

    init() {
        stateStore = CodexStateStore()
        tailWatcher = CodexTailWatcher(stateStore: stateStore)
        wireTail()
        // 宿主单元测试会启动 app 可执行文件。测试进程中禁止抢占真实串口、
        // 自动上传主题或安装全局键盘事件 tap。
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        guard !isRunningTests else { return }
        wireNativeCodexMicro()
        microHID.start()
        wireSerialPort()
        startTail()
        connectFirstMK20()
        hidWatcher.onKey = { [weak self] row, col, pressed in
            Task { @MainActor [weak self] in
                self?.handlePhysicalKey(row: row, col: col, pressed: pressed)
            }
        }
        hidWatcher.onEncoder = { [weak self] control, pressed in
            Task { @MainActor [weak self] in
                self?.handleEncoder(control, pressed: pressed)
            }
        }
        hidWatcher.onDiagnostic = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appendEvent(message)
            }
        }
        permissionObserver = NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInputMonitoringPermission()
                self?.refreshAccessibilityPermission()
            }
        }
        refreshInputMonitoringPermission()
        requestInitialInputMonitoringPermissionIfNeeded()
        refreshAccessibilityPermission()
    }

    deinit {
        pushTimer?.invalidate()
        handshakeTimeoutTask?.cancel()
        reconnectTask?.cancel()
        autoDeployTask?.cancel()
        stateThemeRefreshTask?.cancel()
        uploadTimeoutTask?.cancel()
        permissionObserver?.cancel()
        hidWatcher.stop()
        microHID.stop()
        serialPort.close()
    }

    // MARK: - 设备端原生 Codex Micro

    private func wireNativeCodexMicro() {
        microHID.onConnectedChanged = { [weak self] connected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nativeMicroConnected = connected
                if !connected { self.microHostConnected = false }
                self.appendEvent(connected
                    ? "MK20 已原生枚举为 Codex Micro (303A:8360)"
                    : "Codex Micro HID 已断开")
                if connected {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, self.nativeMicroConnected else { return }
                        self.microHID.probeBridge()
                    }
                }
            }
        }
        microHID.onHostHandshake = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.microHostConnected else { return }
                self.microHostConnected = true
                self.appendEvent("Codex 已通过物理 HID 完成 Micro 握手")
            }
        }
        microHID.onBridgeProbeResponse = { [weak self] response in
            Task { @MainActor [weak self] in
                self?.appendEvent("Codex Micro HID 桥自检通过：\(response)")
            }
        }
        microHID.onError = { [weak self] message in
            Task { @MainActor [weak self] in self?.appendEvent("⚠ \(message)") }
        }
    }

    // MARK: - Tail 接线

    private func wireTail() {
        tailWatcher.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleTailEvent(event)
            }
        }
        tailWatcher.onSessionsChanged = { [weak self] sessions in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessions = sessions
                if sessions.isEmpty {
                    self.selectedSessionIndex = 0
                } else if self.selectedSessionIndex >= sessions.count {
                    self.selectedSessionIndex = sessions.count - 1
                }
                for slot in 0..<self.slotProjects.count {
                    self.slotProjects[slot] = sessions.indices.contains(slot)
                        ? sessions[slot].project
                        : ""
                    if !sessions.indices.contains(slot) {
                        self.slotStates[slot] = .idle
                    }
                }
                let validAttention = Set(
                    self.completionAttentionSlots.filter { sessions.indices.contains($0) }
                )
                if validAttention != self.completionAttentionSlots {
                    self.completionAttentionSlots = validAttention
                    self.scheduleStateThemeRefresh()
                }
                self.pushStatusTexts()
            }
        }
    }

    func startTail() {
        guard !tailRunning else { return }
        tailWatcher.start()
        tailRunning = true
        appendEvent("会话 tail 已启动(\(tailWatcher.sessionsRoot.path))")
    }

    func stopTail() {
        tailWatcher.stop()
        tailRunning = false
        appendEvent("会话 tail 已停止")
    }

    // MARK: - 事件处理

    private func handleTailEvent(_ event: CodexTailEvent) {
        // 消息中心: 全量(去重由 event.id 保证 — tail 只进一次, 无需再查)。
        if !event.isTokenCount {
            messages.insert(event, at: 0)
            if messages.count > 200 { messages.removeLast(messages.count - 200) }
            // 气泡: user/agent 消息与过程事件都显示(过程事件是短文本, 天然一行)。
            bubbleText = CodexSessionParser.shorten(event.text, limit: 46)
            bubbleTime = event.time
            bubbleKind = event.kind.panelLabel
            if let index = sessions.firstIndex(where: { $0.project == event.project }) {
                selectedSessionIndex = index
            }
        } else {
            latestUsage = event
        }

        // 会话槽状态: task_started → working, task_complete → done;
        // 项目 → 首见顺序分配槽位。
        switch event.kind {
        case .taskStarted:
            let slot = assignSlot(project: event.project, state: .working)
            if completionAttentionSlots.remove(slot) != nil {
                scheduleStateThemeRefresh()
            }
        case .taskComplete:
            let slot = assignSlot(project: event.project, state: .done)
            completionAttentionSlots.insert(slot)
            playCompletionSound(project: event.project, slot: slot)
            scheduleStateThemeRefresh()
        case .userMessage, .agentMessage, .reasoning, .functionCall, .toolResult:
            if slotState(for: event.project) == nil {
                _ = assignSlot(project: event.project, state: .working)
            }
        case .tokenCount:
            break
        }
        pushStatusTexts()
    }

    /// 项目 → 槽位(首见顺序, 占满复用最旧)。
    @discardableResult
    private func assignSlot(project: String, state: PetSlotState) -> Int {
        let slot: Int
        if let known = slotProjects.firstIndex(of: project), known < 6 {
            slot = known
        } else if let empty = slotProjects.firstIndex(of: "") {
            slot = empty
        } else {
            slot = slotLastActivity.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
        }
        slotProjects[slot] = project
        slotStates[slot] = state
        slotLastActivity[slot] = Date()
        return slot
    }

    private func slotState(for project: String) -> PetSlotState? {
        guard let index = slotProjects.firstIndex(of: project) else { return nil }
        return slotStates.indices.contains(index) ? slotStates[index] : nil
    }

    private func playCompletionSound(project: String, slot: Int) {
        guard completionSoundEnabled else { return }
        if completionSound?.play() != true {
            NSSound.beep()
        }
        appendEvent("🔔 会话键\(slot + 1) · \(project) 执行完成")
    }

    /// 状态键帽是主题资产，必须经文件通道刷新。连续事件先防抖；若串口正在
    /// 上传，则等待状态机回到 idle，避免两次 FILE_START 交错卡住设备。
    private func scheduleStateThemeRefresh() {
        guard mk20Connected else { return }
        // Hardware self-test must observe a stable HID source. Reloading a
        // theme temporarily tears down the MK20 keyboard endpoint and can
        // swallow the exact press that is being diagnosed. Keep accumulating
        // slot state in memory and apply it once the test ends.
        guard !hardwareSelfTest.isEnabled else { return }
        // A full theme is roughly 0.5 MB. Channel 3 uses 64-byte HID control
        // reports, so redeploying it for every state animation takes minutes.
        // The already-installed theme remains active; live panel text still
        // travels over the fast cmd=1 path.
        guard preferredPort != SerialPort.rawUSBPath else {
            pushStatusTexts()
            return
        }
        stateThemeRefreshTask?.cancel()
        stateThemeRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            while self.isDeployingTheme || self.isInstallingNativeMicro || self.uploadPhase != .idle {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            // Reloading while a key report is in flight can swallow its key-up
            // packet and leave that usage latched inside the MK20. Require a
            // quiet window before automatic state-animation theme refreshes.
            while ProcessInfo.processInfo.systemUptime - self.lastHIDInputAt < 2.0 {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            guard self.mk20Connected, !self.hardwareSelfTest.isEnabled else { return }
            self.stateThemeRefreshTask = nil
            self.deployTheme()
        }
    }

    // MARK: - MK20 连接

    func connectFirstMK20() {
        shouldAutoReconnect = true
        let ports = SerialPort.availablePorts()
        guard !ports.isEmpty else {
            connectionStatus = "未发现 MK20 串口，将自动重试"
            scheduleReconnect()
            return
        }
        let candidates = ports.filter {
            $0 == SerialPort.rawUSBPath || $0.contains("usbmodem")
        }
        guard !candidates.isEmpty else {
            connectionStatus = "未发现 MK20 USB 控制通道，将自动重试"
            scheduleReconnect()
            return
        }
        let choice = candidates.first {
            $0 == SerialPort.rawUSBPath
        } ?? candidates.first {
            $0.localizedCaseInsensitiveContains("MK20_CODEX")
        } ?? candidates.first {
            $0.contains("usbmodem1")
        } ?? candidates[0]
        appendEvent("检测到 MK20 控制通道 \(choice)，自动连接…")
        connectMK20(port: choice)
    }

    func connectMK20(port: String) {
        guard connectionState == .disconnected else { return }
        guard !port.isEmpty else {
            presentedError = PresentedError(message: "未选择 MK20 串口")
            return
        }
        shouldAutoReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        preferredPort = port
        v2Parser = V2PacketParser()
        requestedSystemData = []
        lastPushSignature = ""
        connectionStatus = "正在打开 \((port as NSString).lastPathComponent)…"
        do {
            try serialPort.open(path: port)
            _ = serialPort.setDataTerminalReady(true)
            _ = serialPort.setRequestToSend(false)
            connectionState = .connecting
            mk20Connecting = true
            connectionStatus = "串口已打开，正在唤醒 MK20…"
            appendEvent("串口已打开，开始 V2 握手")
            serialPort.write(Data(repeating: 0x30, count: 64)) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sendOfficialHandshake() }
            }
            handshakeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.connectionState == .connecting else { return }
                    self.handleConnectionLoss("握手 8 秒无响应")
                }
            }
        } catch {
            connectionState = .disconnected
            mk20Connecting = false
            connectionStatus = "串口打开失败，将自动重试"
            presentedError = PresentedError(message: "串口打开失败：\(error.localizedDescription)")
            scheduleReconnect()
        }
    }

    func disconnectMK20() {
        shouldAutoReconnect = false
        disconnectMK20(scheduleReconnect: false, reason: "用户断开")
    }

    private func disconnectMK20(scheduleReconnect: Bool, reason: String) {
        if !scheduleReconnect {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        autoDeployTask?.cancel()
        autoDeployTask = nil
        stateThemeRefreshTask?.cancel()
        stateThemeRefreshTask = nil
        pushTimer?.invalidate()
        pushTimer = nil
        failUpload(reason: "连接已断开", showAlert: false)
        serialPort.close()
        connectionState = .disconnected
        mk20Connected = false
        mk20Connecting = false
        requestedSystemData = []
        connectionStatus = scheduleReconnect ? "MK20 已断开，将自动重连" : "MK20 已断开"
        appendEvent("MK20 已断开（\(reason)）")
        if scheduleReconnect { self.scheduleReconnect() }
    }

    private func wireSerialPort() {
        serialPort.onData = { [weak self] data in
            guard let self else { return }
            let packets = self.v2Parser.append(data)
            Task { @MainActor [weak self] in self?.handleV2Packets(packets) }
        }
        serialPort.onDisconnect = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleConnectionLoss(error?.localizedDescription ?? "USB 串口关闭")
            }
        }
    }

    /// 已验证的量产 V2 时序：'0'×64 → FIND_DEVICE → 无条件发送 connect。
    /// FIND_DEVICE 只证明串口可用；connect 才会让固件推送 deviceRequestSystemData。
    private func sendOfficialHandshake() {
        guard connectionState == .connecting else { return }
        connectionStatus = "正在识别 MK20 V2 协议…"
        serialPort.write(v2Encoder.encode(command: .findDevice, payload: Data())) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.connectionState == .connecting else { return }
                switch result {
                case .success:
                    self.sendConnectHandshake()
                case .failure(let error):
                    self.handleConnectionLoss("FIND_DEVICE 写入失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func sendConnectHandshake() {
        guard connectionState == .connecting else { return }
        let object: [String: Any] = ["connect": true, "deviceProtocolVersion": "V2"]
        if let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            serialPort.write(v2Encoder.encode(command: .sendJSON, payload: payload))
            connectionStatus = "已发送 connect，等待设备状态…"
        }
    }

    private func handleV2Packets(_ packets: [V2Packet]) {
        for packet in packets {
            guard let command = V2Command(rawValue: packet.command) else { continue }
            switch command {
            case .sendJSON, .rpcJSON:
                handleDeviceJSON(packet.payload)
            case .findDevice:
                handleFindDevice(packet.payload)
                activateConnection()
            case .fileStart, .fileEnd:
                handleUploadAck(command)
            case .reload:
                appendEvent("设备已确认主题重载")
            case .proactiveEvent:
                handleProactiveEvent(packet.payload)
            default:
                break
            }
        }
    }

    /// Non-keyboard theme actions report the physical scan coordinate over
    /// cmd=13. K18 deliberately uses this path because its keyboard HID lane is
    /// unstable on the test unit; all other keys remain on the direct HID path.
    private func handleProactiveEvent(_ payload: Data) {
        do {
            let events = try V2NestedDecoder.decodeProactiveEvents(payload)
            guard let keyState = events.first(where: { $0.type == "keyState" }),
                  let row = keyState.row,
                  let col = keyState.col,
                  let pressed = keyState.isPressed else { return }
            // Keyboard-backed keys already arrive through IOHID. The serial
            // path exists only to recover K18's non-keyboard theme action.
            guard row == 3, col == 2 else { return }
            appendEvent(
                "MK20 串口物理键 row=\(row) col=\(col) pressed=\(pressed ? 1 : 0)"
            )
            handlePhysicalKey(row: row, col: col, pressed: pressed)
        } catch {
            appendEvent("⚠ MK20 主动按键事件解析失败：\(error.localizedDescription)")
        }
    }

    private func handleFindDevice(_ payload: Data) {
        guard let values = try? QtDataStream.decodeStringMap(payload) else {
            deviceSummary = "MK20 · V2（设备信息不可解析）"
            return
        }
        let model = values["screen_model"] ?? values["deviceName"] ?? "MK20"
        let version = values["version"] ?? "V2"
        let width = values["screen_width"] ?? "640"
        let height = values["screen_height"] ?? "656"
        deviceSummary = "\(model) · \(version) · \(width)×\(height)"
        appendEvent("识别到 \(deviceSummary)")
    }

    private func activateConnection() {
        guard !mk20Connected else { return }
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        mk20Connected = true
        mk20Connecting = false
        connectionState = .connected
        reconnectAttempt = 0
        connectionStatus = "已连接 \((preferredPort as NSString).lastPathComponent)"
        appendEvent("MK20 V2 控制通道已连接")
        startPushTimer()
        // Stable production policy: keep the two factory USB functions intact.
        // Allwinner CDC carries V2/theme data while the separate SYK HID device
        // carries keys and encoders. Connecting must never rewrite lunch.sh,
        // install a kernel module, or trigger another physical restart.
        autoDeployTask?.cancel()
        if preferredPort == SerialPort.rawUSBPath {
            appendEvent("⚠ 检测到旧实验 HID 模式；不会自动写设备，可手动恢复标准 USB")
        } else {
            appendEvent("稳定 USB 模式：\(MK20USBPolicy.stableModeLabel)；启动脚本保持不变")
            scheduleThemeRevisionDeploymentIfNeeded()
        }
    }

    /// Device themes survive app updates, so a host-only update is not enough
    /// when a key's serialized HID action changes. Deploy a new revision once;
    /// subsequent launches remain on the fast, non-destructive connect path.
    private func scheduleThemeRevisionDeploymentIfNeeded() {
        let installed = UserDefaults.standard.integer(forKey: installedThemeRevisionKey)
        guard installed < CodexPetThemeBuilder.themeRevision else { return }
        appendEvent(
            "检测到 CodexPet 主题修订 \(installed) → \(CodexPetThemeBuilder.themeRevision)，准备自动部署"
        )
        autoDeployTask?.cancel()
        autoDeployTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.mk20Connected else { return }
            while self.isDeployingTheme || self.isInstallingNativeMicro || self.uploadPhase != .idle {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            self.autoDeployTask = nil
            self.deployTheme()
        }
    }

    private func handleConnectionLoss(_ reason: String) {
        guard connectionState != .disconnected || serialPort.isOpen else { return }
        appendEvent("⚠ \(reason)")
        disconnectMK20(scheduleReconnect: shouldAutoReconnect, reason: reason)
    }

    private func scheduleReconnect() {
        guard shouldAutoReconnect, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(2 + reconnectAttempt, 8)
        connectionStatus = "\(delay) 秒后自动重连（第 \(reconnectAttempt) 次）"
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            guard self.connectionState == .disconnected, self.shouldAutoReconnect else { return }
            let ports = SerialPort.availablePorts()
            if !self.preferredPort.isEmpty, ports.contains(self.preferredPort) {
                self.connectMK20(port: self.preferredPort)
            } else {
                self.connectFirstMK20()
            }
        }
    }

    private func handleDeviceJSON(_ payload: Data) {
        guard !payload.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        if object["method"] as? String == "keyStateChanged",
           let parameters = object["parameters"] as? [String: Any],
           let row = (parameters["row"] as? NSNumber)?.intValue,
           let col = (parameters["col"] as? NSNumber)?.intValue,
           let pressedNumber = parameters["pressed"] as? NSNumber {
            // Do not double-dispatch the 19 keyboard-backed controls. Only
            // K18 intentionally uses JSON as an alternate physical channel.
            guard row == 3, col == 2 else { return }
            let pressed = pressedNumber.boolValue
            appendEvent(
                "MK20 JSON 物理键 row=\(row) col=\(col) pressed=\(pressed ? 1 : 0)"
            )
            handlePhysicalKey(row: row, col: col, pressed: pressed)
            return
        }
        if let requested = object["deviceRequestSystemData"] as? [String], !requested.isEmpty {
            var keys = Set(requested)
            keys.formUnion(CodexPetThemeBuilder.panelDataKeys)
            requestedSystemData = keys
            activateConnection()
            startPushTimer()
            appendEvent("设备请求系统数据：\(requested.sorted().joined(separator: ", "))")
            // 主题刚重载时立即喂一次，避免必须等下一轮 2 秒定时器。
            pushStatusTexts()
        }
    }

    // MARK: - 副屏推送(cmd=1)

    private func startPushTimer() {
        guard pushTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pushStatusTexts() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pushTimer = timer
    }

    /// 当前状态 → 五行副屏文本 → cmd=1。
    func pushStatusTexts() {
        guard mk20Connected, uploadPhase == .idle else { return }
        if hardwareSelfTest.isEnabled {
            pushHardwareSelfTestTexts()
            return
        }
        var values: [String: String] = [
            CodexPetThemeBuilder.statusKey: statusLine(),
            CodexPetThemeBuilder.bubbleKey: bubbleLine(),
            CodexPetThemeBuilder.projectKey: overviewLine(),
        ]
        // 用量行 + 进度条。
        if let usage = latestUsage {
            values[CodexPetThemeBuilder.usageKey] = usageLine(usage)
            values[CodexPetThemeBuilder.quotaDetailKey] = quotaDetailLine(usage)
            values[CodexPetThemeBuilder.quotaKey] =
                String(usage.primaryPercent ?? 0)
        } else {
            values[CodexPetThemeBuilder.usageKey] = "tokens —"
            values[CodexPetThemeBuilder.quotaDetailKey] = "额度 —"
            values[CodexPetThemeBuilder.quotaKey] = "0"
        }
        let signature = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "|")
        let shouldLog = signature != lastPushSignature
        lastPushSignature = signature
        serialPort.write(
            v2Encoder.encodeSystemData(values)
        ) { [weak self] result in
            guard shouldLog else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let count):
                    self.appendEvent("副屏动态数据已写入(\(count)B)：\(signature)")
                case .failure(let error):
                    self.appendEvent("⚠ 副屏动态数据写入失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func pushHardwareSelfTestTexts() {
        let test = hardwareSelfTest
        let values: [String: String] = [
            CodexPetThemeBuilder.statusKey: "硬件自检 · Codex 动作已屏蔽",
            CodexPetThemeBuilder.bubbleKey: "最近：\(test.lastEvent)",
            CodexPetThemeBuilder.projectKey:
                "按键 \(test.testedKeyCount)/20 · 旋钮 \(test.testedEncoderCount)/6 · HID✓",
            CodexPetThemeBuilder.usageKey: "已接收 \(test.totalPressCount) 次有效输入",
            CodexPetThemeBuilder.quotaDetailKey: "退出自检后恢复正常控制",
            CodexPetThemeBuilder.quotaKey: String(test.coveragePercent),
        ]
        writeStatusValues(values)
    }

    private func writeStatusValues(_ values: [String: String]) {
        let signature = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "|")
        let shouldLog = signature != lastPushSignature
        lastPushSignature = signature
        serialPort.write(v2Encoder.encodeSystemData(values)) { [weak self] result in
            guard shouldLog else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let count):
                    self.appendEvent("副屏动态数据已写入(\(count)B)：\(signature)")
                case .failure(let error):
                    self.appendEvent("⚠ 副屏动态数据写入失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func statusLine() -> String {
        guard let index = currentSessionIndex else { return "CodexPet · 等待会话" }
        let project = CodexSessionParser.shorten(sessions[index].project, limit: 18)
        let state = slotStates.indices.contains(index) ? slotStates[index].label : "空闲"
        return "#\(index + 1) \(project) · \(state)"
    }

    private func bubbleLine() -> String {
        "\(bubbleTime) \(bubbleKind) · \(bubbleText)"
    }

    private func overviewLine() -> String {
        let working = slotStates.filter { $0 == .working || $0 == .needsInput }.count
        let done = slotStates.filter { $0 == .done }.count
        let hid = hidCaptureActive ? "HID✓" : "HID!"
        let attention = completionAttentionSlots.isEmpty
            ? ""
            : " · \(completionAttentionSlots.count)待查看"
        return "\(sessions.count)会话 · \(working)运行 · \(done)完成\(attention) · \(hid)"
    }

    private func usageLine(_ usage: CodexTailEvent) -> String {
        let tokens = PetDeckViewModel.formatTokens(usage.totalTokens ?? 0)
        return "tokens \(tokens)"
    }

    private func quotaDetailLine(_ usage: CodexTailEvent) -> String {
        var parts: [String] = []
        if usage.primaryAvailable == true, let percent = usage.primaryPercent {
            let label = usage.primaryLabel ?? "主额度"
            let reset = usage.primaryReset.map { " ↻\($0)" } ?? ""
            parts.append("\(label) \(percent)%\(reset)")
        }
        if usage.secondaryAvailable == true, let percent = usage.secondaryPercent {
            let label = usage.secondaryLabel ?? "次额度"
            let reset = usage.secondaryReset.map { " ↻\($0)" } ?? ""
            parts.append("\(label) \(percent)%\(reset)")
        }
        return parts.isEmpty ? "额度 —" : parts.joined(separator: "  |  ")
    }

    /// token 数 → 人读格式(33.1B / 2.6M / 1.5k)。
    nonisolated static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return String(value)
    }

    // MARK: - 主题部署

    /// §8.1 上传状态机(与 ScreenKeySwiftUI DeckViewModel 同款链路)。
    func deployTheme() {
        guard mk20Connected else {
            presentedError = PresentedError(message: "请先连接 MK20")
            return
        }
        guard !isDeployingTheme, !isInstallingNativeMicro, uploadPhase == .idle else { return }
        isDeployingTheme = true
        themeUploadProgress = 0
        do {
            let data = try CodexPetThemeFactory.buildThemeData(
                slotStates: slotStates,
                projectNames: slotProjects,
                completionAttentionSlots: completionAttentionSlots
            )
            appendEvent("CodexPet 主题已生成(\(data.count) 字节), 开始上传…")
            try beginUpload(
                data: data,
                devicePath: "/data/theme/MK20/CodexPet.Theme",
                purpose: .theme
            )
        } catch {
            failUpload(reason: error.localizedDescription, showAlert: true)
        }
    }

    /// Kept as a hard safety boundary for older UI/call sites. Production
    /// builds never install a custom gadget or modify the MK20 boot launcher.
    func installNativeMicro() {
        appendEvent("已阻止 Codex Micro 实验组件写入；当前固定使用稳定 USB 模式")
        presentedError = PresentedError(
            message: "Codex Micro 实验通道已停用。MK20 将继续使用原厂 CDC + 物理 HID。"
        )
    }

    /// Restores the stock MK20 USB startup path on the next physical restart.
    /// This remains available over the HID channel-3 V2 endpoint.
    func restoreStockUSB() {
        beginNativeInstall(
            resources: [
                (name: "mk20-recover-lunch", extension: "sh",
                 path: "/mnt/SDCARD/lunch.sh"),
            ]
        )
    }

    private func beginNativeInstall(
        resources: [(name: String, extension: String?, path: String)]
    ) {
        guard mk20Connected else {
            presentedError = PresentedError(message: "请先连接 MK20")
            return
        }
        guard !isDeployingTheme, !isInstallingNativeMicro, uploadPhase == .idle else { return }
        var items: [NativeInstallItem] = []
        for resource in resources {
            guard let url = Bundle.main.url(
                forResource: resource.name,
                withExtension: resource.extension
            ), let data = try? Data(contentsOf: url), !data.isEmpty else {
                presentedError = PresentedError(message: "应用内缺少 MK20 USB 组件，请重新构建")
                return
            }
            items.append(NativeInstallItem(path: resource.path, data: data))
        }
        nativeInstallQueue = items
        nativeInstallTotalBytes = items.reduce(0) { $0 + $1.data.count }
        nativeInstallCompletedBytes = 0
        nativeInstallProgress = 0
        nativeInstallNeedsRestart = false
        isInstallingNativeMicro = true
        appendEvent("开始恢复 MK20 标准 USB 启动方式…")
        beginNextNativeInstallItem()
    }

    private enum UploadPhase {
        case idle
        case awaitingFileStart
        case awaitingFileEnd
    }
    private enum UploadPurpose {
        case theme
        case nativeMicro
    }
    private struct NativeInstallItem {
        let path: String
        let data: Data
    }
    private var uploadPhase = UploadPhase.idle
    private var uploadPurpose = UploadPurpose.theme
    private var uploadDevicePath = ""
    private var uploadPayload = Data()
    private var uploadOffset = 0
    private var uploadWritten = 0
    private let uploadChunkSize = 4_096
    private var nativeInstallQueue: [NativeInstallItem] = []
    private var nativeInstallTotalBytes = 0
    private var nativeInstallCompletedBytes = 0
    private func beginUpload(data: Data, devicePath: String, purpose: UploadPurpose) throws {
        guard serialPort.isOpen else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "串口未打开"])
        }
        uploadPhase = .awaitingFileStart
        uploadPurpose = purpose
        uploadDevicePath = devicePath
        uploadPayload = data
        uploadOffset = 0
        uploadWritten = 0
        connectionStatus = purpose == .theme ? "正在初始化主题传输…" : "正在写入标准 USB 恢复脚本…"
        armUploadTimeout()
        // V2.30 实测顺序不可交换：cmd=3 → Abort → FILE_START；未等
        // FILE_START ACK 就写裸数据会让固件卡死到物理重插。
        serialPort.write(v2Encoder.encode(command: .getTheme, payload: Data()))
        serialPort.write(V2PacketEncoder.abortTransferMessage)
        serialPort.write(v2Encoder.encode(
            command: .fileStart,
            payload: QtDataStream.encodeStringMap([devicePath: String(data.count)])
        ))
    }

    private func beginNextNativeInstallItem() {
        guard isInstallingNativeMicro else { return }
        guard !nativeInstallQueue.isEmpty else {
            isInstallingNativeMicro = false
            nativeInstallProgress = 1
            nativeInstallNeedsRestart = true
            connectionStatus = "标准 USB 恢复脚本已写入；请拔插 MK20"
            appendEvent("标准 USB 恢复脚本已写入；拔插后回到原厂 CDC")
            return
        }
        let item = nativeInstallQueue.removeFirst()
        do {
            try beginUpload(data: item.data, devicePath: item.path, purpose: .nativeMicro)
        } catch {
            failUpload(reason: error.localizedDescription, showAlert: true)
        }
    }

    private func handleUploadAck(_ command: V2Command) {
        switch (uploadPhase, command) {
        case (.awaitingFileStart, .fileStart):
            uploadPhase = .awaitingFileEnd
            connectionStatus = "设备已允许写入，正在上传主题…"
            sendUploadChunks()
        case (.awaitingFileEnd, .fileEnd):
            uploadPhase = .idle
            switch uploadPurpose {
            case .theme:
                // The device reloads its key page without disconnecting USB.
                // If that transition drops a key-up report, the host would
                // otherwise regard that particular key as held forever.
                hidWatcher.resetPressedState()
                serialPort.write(v2Encoder.encode(command: .reload, payload: Data(uploadDevicePath.utf8)))
                UserDefaults.standard.set(
                    CodexPetThemeBuilder.themeRevision,
                    forKey: installedThemeRevisionKey
                )
                themeUploadProgress = 1
                connectionStatus = "已连接 · CodexPet 主题部署完成"
                appendEvent("主题上传完成，已发送重载命令")
                resetUploadBuffers()
                isDeployingTheme = false
            case .nativeMicro:
                nativeInstallCompletedBytes += uploadPayload.count
                nativeInstallProgress = min(
                    Double(nativeInstallCompletedBytes) / Double(max(nativeInstallTotalBytes, 1)),
                    0.99
                )
                appendEvent("已写入 \(uploadDevicePath)")
                resetUploadBuffers()
                beginNextNativeInstallItem()
            }
        default:
            break
        }
    }

    private func sendUploadChunks() {
        while uploadOffset < uploadPayload.count {
            let end = min(uploadOffset + uploadChunkSize, uploadPayload.count)
            let chunk = uploadPayload.subdata(in: uploadOffset..<end)
            serialPort.write(chunk) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isDeployingTheme || self.isInstallingNativeMicro else { return }
                    switch result {
                    case .success(let count):
                        self.uploadWritten += count
                        switch self.uploadPurpose {
                        case .theme:
                            self.themeUploadProgress = min(
                                Double(self.uploadWritten) / Double(max(self.uploadPayload.count, 1)) * 0.95,
                                0.95
                            )
                        case .nativeMicro:
                            self.nativeInstallProgress = min(
                                Double(self.nativeInstallCompletedBytes + self.uploadWritten)
                                    / Double(max(self.nativeInstallTotalBytes, 1)) * 0.99,
                                0.99
                            )
                        }
                    case .failure(let error):
                        self.handleConnectionLoss("主题写入失败：\(error.localizedDescription)")
                    }
                }
            }
            uploadOffset = end
        }
        // 数据队列写完后 FILE_END + 立即 Abort。Abort 是触发 FILE_END ACK 的
        // 一部分，不能先等 ACK 再发，否则设备与宿主互相等待。
        serialPort.write(v2Encoder.encode(
            command: .fileEnd,
            payload: QtDataStream.encodeStringMap([uploadDevicePath: String(CRC32.checksum(uploadPayload))])
        ))
        serialPort.write(V2PacketEncoder.abortTransferMessage)
    }

    private func armUploadTimeout() {
        uploadTimeoutTask?.cancel()
        let timeoutSeconds = preferredPort == SerialPort.rawUSBPath ? 300 : 120
        uploadTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled, let self,
                  self.isDeployingTheme || self.isInstallingNativeMicro else { return }
            let reason = "\(timeoutSeconds) 秒内未收到文件传输应答，请拔插 MK20 后重试"
            self.presentedError = PresentedError(message: "文件部署失败：\(reason)")
            self.handleConnectionLoss(reason)
        }
    }

    private func resetUploadBuffers() {
        uploadTimeoutTask?.cancel()
        uploadTimeoutTask = nil
        uploadPhase = .idle
        uploadPayload = Data()
        uploadOffset = 0
        uploadWritten = 0
    }

    private func failUpload(reason: String, showAlert: Bool) {
        guard isDeployingTheme || isInstallingNativeMicro || uploadPhase != .idle else { return }
        appendEvent("⚠ 文件部署失败：\(reason)")
        resetUploadBuffers()
        isDeployingTheme = false
        isInstallingNativeMicro = false
        nativeInstallQueue.removeAll()
        themeUploadProgress = 0
        nativeInstallProgress = 0
        if showAlert {
            presentedError = PresentedError(message: "文件部署失败：\(reason)")
        }
    }

    // MARK: - MK20 按键 → Codex Desktop

    var inputMonitoringStatusText: String {
        switch inputMonitoringPermission {
        case .granted:
            return hidCaptureActive ? "已授权 · 已监听" : "已授权 · 监听启动失败"
        case .denied:
            return "已拒绝"
        case .notDetermined:
            return "尚未授权"
        }
    }

    var inputMonitoringActionTitle: String {
        switch inputMonitoringPermission {
        case .granted: "重试"
        case .denied: "打开设置"
        case .notDetermined: "授权…"
        }
    }

    func refreshInputMonitoringPermission() {
        let current = MK20HIDWatcher.permissionState()
        inputMonitoringPermission = current
        guard current == .granted else {
            hidWatcher.stop()
            hidCaptureActive = false
            return
        }
        hidWatcher.start()
        hidCaptureActive = hidWatcher.tapActive
    }

    /// 首次运行稳定签名版时主动登记输入监控请求。部分 macOS 版本会在尚未
    /// 登记时直接返回 denied，因此这里对所有“未授权”状态只请求一次。
    /// macOS 仍由用户最终批准；之后需要重试时可使用界面上的“打开设置”。
    private func requestInitialInputMonitoringPermissionIfNeeded() {
        guard inputMonitoringPermission != .granted else { return }
        let defaults = UserDefaults.standard
        let requestKey = "didRequestStableInputMonitoringPermission"
        guard !defaults.bool(forKey: requestKey) else { return }
        defaults.set(true, forKey: requestKey)

        let granted = MK20HIDWatcher.requestPermission()
        refreshInputMonitoringPermission()
        appendEvent(granted
            ? "输入监控权限已授予，MK20 按键监听已启动"
            : "已自动请求输入监控权限；请在系统设置中允许 CodexPetDeck Direct")
    }

    func requestInputMonitoringPermission() {
        if inputMonitoringPermission == .granted {
            refreshInputMonitoringPermission()
            return
        }

        let granted = MK20HIDWatcher.requestPermission()
        refreshInputMonitoringPermission()
        if granted {
            appendEvent("输入监控权限已授予，MK20 按键监听已重新启动")
            return
        }

        appendEvent("已请求输入监控权限；请在系统设置中允许 CodexPetDeck Direct")
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshAccessibilityPermission() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if accessibilityGranted {
            appendEvent("辅助功能权限已授予，Codex 动作键可用")
            return
        }
        appendEvent("已请求辅助功能权限；请在系统设置中允许 CodexPetDeck Direct")
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    private var currentSessionIndex: Int? {
        guard !sessions.isEmpty else { return nil }
        return min(max(selectedSessionIndex, 0), sessions.count - 1)
    }

    private func showSession(at index: Int, prefix: String) {
        guard sessions.indices.contains(index) else {
            appendEvent("⚠ \(prefix)：该槽暂无 Codex 会话")
            return
        }
        selectedSessionIndex = index
        if completionAttentionSlots.remove(index) != nil {
            scheduleStateThemeRefresh()
        }
        let session = sessions[index]
        logDesktopOutcome(codexDesktop.openThread(session), prefix: prefix)
        if let hit = messages.first(where: { $0.project == session.project }) {
            bubbleText = CodexSessionParser.shorten(hit.text, limit: 46)
            bubbleTime = hit.time
            bubbleKind = hit.kind.panelLabel
        } else {
            setActionBubble("已切换到 \(session.project)")
        }
        pushStatusTexts()
    }

    private func switchSession(by offset: Int, action: PetAction) {
        guard let current = currentSessionIndex, !sessions.isEmpty else {
            appendEvent("⚠ MK20 \(action.title)：暂无 Codex 会话")
            return
        }
        let count = sessions.count
        let target = (current + offset + count) % count
        showSession(at: target, prefix: "MK20 \(action.title) → \(action.hidKey)")
    }

    private func copyLastReply(action: PetAction) {
        guard let index = currentSessionIndex else {
            appendEvent("⚠ MK20 \(action.title)：暂无 Codex 会话")
            return
        }
        let project = sessions[index].project
        guard let reply = messages.first(where: {
            $0.project == project && $0.kind == .agentMessage
        }) else {
            appendEvent("⚠ MK20 \(action.title)：当前会话还没有助手回复")
            return
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(reply.text, forType: .string) else {
            appendEvent("⚠ MK20 \(action.title)：写入剪贴板失败")
            return
        }
        setActionBubble("已复制当前会话最近答复")
        appendEvent("MK20 \(action.title) → \(action.hidKey)：已复制 \(project) 最近答复")
        pushStatusTexts()
    }

    private func openCurrentProject(action: PetAction) {
        guard let index = currentSessionIndex else {
            appendEvent("⚠ MK20 \(action.title)：暂无 Codex 会话")
            return
        }
        let session = sessions[index]
        let url = URL(fileURLWithPath: session.cwd, isDirectory: true)
        guard FileManager.default.fileExists(atPath: session.cwd), NSWorkspace.shared.open(url) else {
            appendEvent("⚠ MK20 \(action.title)：无法打开 \(session.cwd)")
            return
        }
        setActionBubble("已打开 \(session.project) 目录")
        appendEvent("MK20 \(action.title) → \(action.hidKey)：已打开 \(session.cwd)")
        pushStatusTexts()
    }

    private func setActionBubble(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        bubbleTime = formatter.string(from: Date())
        bubbleKind = "按键"
        bubbleText = CodexSessionParser.shorten(text, limit: 46)
    }

    // MARK: - 硬件自检

    func startHardwareSelfTest() {
        // Cancel refreshes that were scheduled by a completion event before
        // self-test started. The installed revision already owns the distinct
        // key/encoder usages, so no theme upload is needed to enter the test.
        stateThemeRefreshTask?.cancel()
        stateThemeRefreshTask = nil
        autoDeployTask?.cancel()
        autoDeployTask = nil
        resetK18Recovery()
        hardwareSelfTest.start()
        encoderPulseGate = EncoderPulseGate()
        lastPushSignature = ""
        appendEvent("🧪 硬件自检已启动：所有 Codex 动作已屏蔽")
        pushStatusTexts()
    }

    func stopHardwareSelfTest() {
        guard hardwareSelfTest.isEnabled else { return }
        resetK18Recovery()
        hardwareSelfTest.stop()
        encoderPulseGate = EncoderPulseGate()
        lastPushSignature = ""
        setActionBubble("硬件自检结束")
        appendEvent("🧪 硬件自检已结束：Codex 控制已恢复")
        pushStatusTexts()
        // If self-test interrupted a required layout revision, deploy that
        // first. Otherwise one debounced refresh applies any slot-state changes
        // that accumulated while the device was being tested.
        let installed = UserDefaults.standard.integer(forKey: installedThemeRevisionKey)
        if installed < CodexPetThemeBuilder.themeRevision {
            scheduleThemeRevisionDeploymentIfNeeded()
        } else {
            scheduleStateThemeRefresh()
        }
    }

    func resetHardwareSelfTest() {
        guard hardwareSelfTest.isEnabled else { return }
        resetK18Recovery()
        hardwareSelfTest.reset()
        encoderPulseGate = EncoderPulseGate()
        lastPushSignature = ""
        appendEvent("🧪 硬件自检计数已清零")
        pushStatusTexts()
    }

    private func handlePhysicalKey(row: Int, col: Int, pressed: Bool) {
        lastHIDInputAt = ProcessInfo.processInfo.systemUptime
        guard pressed else { return }

        // The affected unit scans physical K18 as K17 + K19 in the same HID
        // burst. Delay those two neighbours very briefly: a pair becomes one
        // synthetic K18, while a lone neighbour keeps its original action.
        if row == 3, col == 1 || col == 3 {
            handleK18NeighborCandidate(column: col)
            return
        }
        dispatchPhysicalKey(row: row, col: col)
    }

    private func handleK18NeighborCandidate(column: Int) {
        if let pending = pendingK18NeighborColumn, pending != column {
            pendingK18NeighborTask?.cancel()
            pendingK18NeighborTask = nil
            pendingK18NeighborColumn = nil
            appendEvent("MK20 K18 邻键和弦恢复：K17 + K19 → K18")
            dispatchPhysicalKey(row: 3, col: 2)
            return
        }
        guard pendingK18NeighborColumn == nil else { return }
        pendingK18NeighborColumn = column
        pendingK18NeighborTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.k18ChordWindow)
            guard !Task.isCancelled,
                  self.pendingK18NeighborColumn == column else { return }
            self.pendingK18NeighborColumn = nil
            self.pendingK18NeighborTask = nil
            self.dispatchPhysicalKey(row: 3, col: column)
        }
    }

    private func resetK18Recovery() {
        pendingK18NeighborTask?.cancel()
        pendingK18NeighborTask = nil
        pendingK18NeighborColumn = nil
    }

    private func dispatchPhysicalKey(row: Int, col: Int) {
        // Serial cmd=13 and the neighbour-chord fallback can both recover the
        // same physical K18 press. Collapse them into one logical activation.
        if row == 3, col == 2 {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastK18ActivationAt >= 0.3 else { return }
            lastK18ActivationAt = now
        }
        guard let role = CodexPetThemeBuilder.physicalLayout()
            .first(where: { $0.row == row && $0.col == col })?.role else { return }

        // Codex Micro AG00...AG05 select hardware Agent slots; they are not
        // deep links to the user's six existing Codex Desktop tasks. The MK20
        // theme therefore uses its keyboard report only as a physical event,
        // and the companion performs the documented desktop action directly.
        // This also prevents native + desktop execution from firing an action
        // twice. Vendor-HID enumeration/handshake remains active independently.
        if hardwareSelfTest.isEnabled {
            hardwareSelfTest.recordKey(row: row, col: col, role: role)
            appendEvent("🧪 自检按键：\(hardwareSelfTest.lastEvent)")
            pushStatusTexts()
            return
        }
        switch role {
        case .session(let slot):
            showSession(at: slot, prefix: "MK20 会话键\(slot + 1) → \(role.hidKey)")
        case .action(let action):
            performDeckAction(action)
        }
    }

    private func handleEncoder(_ control: MK20EncoderControl, pressed: Bool) {
        lastHIDInputAt = ProcessInfo.processInfo.systemUptime
        guard pressed else { return }
        let action = control.action
        guard encoderPulseGate.shouldAccept(
            action,
            at: ProcessInfo.processInfo.systemUptime
        ) else { return }
        if hardwareSelfTest.isEnabled {
            hardwareSelfTest.recordEncoder(control)
            appendEvent("🧪 自检旋钮：\(hardwareSelfTest.lastEvent)")
            pushStatusTexts()
            return
        }
        appendEvent("MK20 \(control.title) → \(action.title)")
        performDeckAction(action)
    }

    private func performDeckAction(_ action: PetAction) {
        switch action {
        case .previousSession:
            switchSession(by: -1, action: action)
        case .nextSession:
            switchSession(by: 1, action: action)
        case .copyLastReply:
            copyLastReply(action: action)
        case .openProject:
            openCurrentProject(action: action)
        default:
            setActionBubble(action.title)
            pushStatusTexts()
            codexDesktop.perform(action) { [weak self] outcome in
                self?.logDesktopOutcome(
                    outcome,
                    prefix: "MK20 \(action.title) → \(action.hidKey)"
                )
            }
        }
    }

    @discardableResult
    private func sendNativeMicro(role: PetKeyRole, pressed: Bool) -> Bool {
        switch role {
        case .session(let slot):
            guard CodexMicroProtocol.Keys.agent.indices.contains(slot) else { return false }
            microHID.sendKey(
                CodexMicroProtocol.Keys.agent[slot],
                pressed: pressed,
                agent: slot
            )
            if pressed {
                setActionBubble("Codex Micro 会话键 \(slot + 1)")
                appendEvent("MK20 会话键\(slot + 1) → \(role.hidKey)：已发送原生 Micro 事件")
                pushStatusTexts()
            }
            return true

        case .action(let action):
            guard action.rawValue <= PetAction.voice.rawValue else { return false }
            microHID.sendKey(action.hidKey, pressed: pressed)
            if pressed {
                setActionBubble(action.title)
                appendEvent("MK20 \(action.title) → \(action.hidKey)：已发送原生 Micro 事件")
                pushStatusTexts()
            }
            return true
        }
    }

    private func logDesktopOutcome(
        _ outcome: CodexDesktopController.Outcome,
        prefix: String
    ) {
        switch outcome {
        case .performed(let detail): appendEvent("\(prefix)：\(detail)")
        case .unavailable(let detail): appendEvent("⚠ \(prefix)：\(detail)")
        }
    }

    // MARK: - 日志

    func appendEvent(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "\(formatter.string(from: Date())) \(line)"
        eventLog.insert(entry, at: 0)
        if eventLog.count > 120 { eventLog.removeLast(eventLog.count - 120) }
        // 磁盘镜像: 排障时从外面看到"串口通没通/主题传没传/键到没到"。
        if let handle = FileHandle(forWritingAtPath: Self.eventMirrorURL.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((entry + "\n").utf8))
        } else {
            try? FileManager.default.createDirectory(
                at: Self.eventMirrorURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data((entry + "\n").utf8).write(to: Self.eventMirrorURL)
        }
    }

    static var eventMirrorURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexPetDeck/pet-events.log")
    }
}

extension CodexPetThemeBuilder {
    /// 副屏全部数据键(cmd=1 合并声明用)。
    static var panelDataKeys: Set<String> {
        [statusKey, bubbleKey, projectKey, usageKey, quotaDetailKey, quotaKey]
    }
}

private extension CodexTailEvent.Kind {
    var panelLabel: String {
        switch self {
        case .taskStarted: "开始"
        case .taskComplete: "完成"
        case .userMessage: "用户"
        case .agentMessage: "答复"
        case .reasoning: "思考"
        case .functionCall: "工具"
        case .toolResult: "结果"
        case .tokenCount: "用量"
        }
    }
}
