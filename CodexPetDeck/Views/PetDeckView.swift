import SwiftUI

/// 主窗口: 左消息中心 + 右控制列(连接/主题/用量/槽位)。
struct PetDeckView: View {
    @ObservedObject var deck: PetDeckViewModel
    @State private var selectedPort = ""

    var body: some View {
        HSplitView {
            messageCenter
                .frame(minWidth: 520, idealWidth: 680)
            controlColumn
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
        }
        .onAppear {
            selectedPort = SerialPort.availablePorts().first ?? ""
        }
        .alert(item: $deck.presentedError) { error in
            Alert(
                title: Text("CodexPetDeck"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: - 左侧: 消息中心

    private var messageCenter: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if deck.messages.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "pawprint")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text(deck.tailRunning ? "等待 Codex 会话事件…" : "会话 tail 未启动")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("在任意项目跑 codex, 事件会实时出现在这里")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(deck.messages.prefix(100)) { event in
                            MessageRow(event: event)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("消息中心")
                    .font(.title3.weight(.semibold))
                Text(deck.tailRunning
                     ? "监听 ~/.codex/sessions(\(deck.sessions.count) 个活跃会话)"
                     : "已停止")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let usage = deck.latestUsage {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("累计 \(PetDeckViewModel.formatTokens(usage.totalTokens ?? 0))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                    if usage.primaryAvailable == true, let percent = usage.primaryPercent {
                        Text("\(usage.primaryLabel ?? "额度") \(percent)%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(percent > 20 ? Color.secondary : Color.orange)
                    }
                }
            }
        }
        .padding(14)
    }

    // MARK: - 右侧: 控制列

    private var controlColumn: some View {
        ScrollView {
            VStack(spacing: 14) {
                mk20Card
                selfTestCard
                themeCard
                slotCard
                eventLogCard
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var mk20Card: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("MK20") {
                    Label(
                        deck.mk20Connected ? "已连接" : (deck.mk20Connecting ? "连接中" : "未连接"),
                        systemImage: deck.mk20Connected
                            ? "checkmark.circle.fill"
                            : (deck.mk20Connecting ? "arrow.triangle.2.circlepath" : "circle.slash")
                    )
                    .foregroundStyle(deck.mk20Connected ? .green : (deck.mk20Connecting ? .orange : .secondary))
                    .font(.caption)
                }

                LabeledContent("状态") {
                    Text(deck.connectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("设备") {
                    Text(deck.deviceSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                LabeledContent("按键监听") {
                    HStack(spacing: 6) {
                        Label(
                            deck.inputMonitoringStatusText,
                            systemImage: deck.hidCaptureActive
                                ? "keyboard.badge.ellipsis"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(deck.hidCaptureActive ? .green : .orange)

                        if !deck.hidCaptureActive {
                            Button(deck.inputMonitoringActionTitle) {
                                deck.requestInputMonitoringPermission()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.medium))
                        }
                    }
                }

                LabeledContent("Codex 控制") {
                    HStack(spacing: 6) {
                        Label(
                            deck.accessibilityGranted ? "桌面直连 · 已授权" : "需要辅助功能权限",
                            systemImage: deck.accessibilityGranted
                                ? "link.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(deck.accessibilityGranted ? .green : .orange)

                        if !deck.accessibilityGranted {
                            Button("授权…") {
                                deck.requestAccessibilityPermission()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.medium))
                        }
                    }
                }

                LabeledContent("USB 模式") {
                    Label(
                        deck.nativeMicroConnected
                            ? "旧实验 HID · 建议恢复"
                            : MK20USBPolicy.stableModeLabel,
                        systemImage: deck.nativeMicroConnected
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(deck.nativeMicroConnected ? Color.orange : Color.green)
                }

                if deck.nativeMicroConnected {
                    Button {
                        deck.restoreStockUSB()
                    } label: {
                        Label("恢复标准 MK20 USB", systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(deck.isInstallingNativeMicro || deck.isDeployingTheme)
                }

                if deck.isInstallingNativeMicro {
                    ProgressView(value: deck.nativeInstallProgress) {
                        Text("正在写入标准 USB 恢复脚本 \(Int(deck.nativeInstallProgress * 100))%")
                            .font(.caption2.monospacedDigit())
                    }
                } else if deck.nativeInstallNeedsRestart {
                    Label("写入完成，请拔下再插入 MK20", systemImage: "powerplug")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text("副屏与主题走原厂 CDC；20 个按键和两枚旋钮走独立 4250:426F HID。应用不会再修改 MK20 启动脚本或安装内核模块。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Picker("控制通道", selection: $selectedPort) {
                    Text("请选择控制通道").tag("")
                    ForEach(SerialPort.availablePorts(), id: \.self) { port in
                        Text(port.replacingOccurrences(of: "/dev/", with: "")).tag(port)
                    }
                }

                HStack {
                    Button("刷新") {
                        selectedPort = SerialPort.availablePorts().first ?? ""
                    }
                    Spacer()
                    Button(deck.mk20Connected || deck.mk20Connecting ? "断开" : "连接") {
                        if deck.mk20Connected || deck.mk20Connecting {
                            deck.disconnectMK20()
                        } else {
                            deck.connectMK20(port: selectedPort)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedPort.isEmpty && !deck.mk20Connected && !deck.mk20Connecting)
                }

                LabeledContent("会话 tail") {
                    Toggle("", isOn: Binding(
                        get: { deck.tailRunning },
                        set: { $0 ? deck.startTail() : deck.stopTail() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            .padding(.top, 6)
        } label: {
            Label("设备", systemImage: "keyboard")
        }
    }

    private var selfTestCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        deck.hardwareSelfTest.isEnabled ? "自检进行中" : "安全检查全部输入",
                        systemImage: deck.hardwareSelfTest.isEnabled
                            ? "waveform.path.ecg.rectangle.fill"
                            : "stethoscope"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(deck.hardwareSelfTest.isEnabled ? Color.orange : Color.secondary)
                    Spacer()
                    if deck.hardwareSelfTest.isEnabled {
                        Button("退出自检") {
                            deck.stopHardwareSelfTest()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    } else {
                        Button("开始自检") {
                            deck.startHardwareSelfTest()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!deck.mk20Connected || deck.isDeployingTheme)
                    }
                }

                if deck.hardwareSelfTest.isEnabled {
                    Label("真实 Codex 动作已屏蔽，可以安全按下所有键和旋钮。", systemImage: "shield.checkered")
                        .font(.caption2)
                        .foregroundStyle(.green)

                    if deck.isDeployingTheme {
                        Label("正在部署独立旋钮映射，请完成后再测试旋钮", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    ProgressView(
                        value: Double(deck.hardwareSelfTest.testedComponentCount),
                        total: 26
                    ) {
                        Text("覆盖 \(deck.hardwareSelfTest.testedComponentCount)/26")
                            .font(.caption2.monospacedDigit())
                    }

                    VStack(spacing: 5) {
                        ForEach(0..<4, id: \.self) { row in
                            HStack(spacing: 5) {
                                ForEach(0..<5, id: \.self) { col in
                                    selfTestKeyCell(row: row, col: col)
                                }
                            }
                        }
                    }

                    Divider()

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3),
                        spacing: 5
                    ) {
                        ForEach(MK20EncoderControl.allCases) { control in
                            selfTestEncoderCell(control)
                        }
                    }

                    HStack {
                        Text("最近：\(deck.hardwareSelfTest.lastEvent)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("清零") {
                            deck.resetHardwareSelfTest()
                        }
                        .font(.caption)
                    }
                } else {
                    Text("自检覆盖 20 个屏幕键，以及左右旋钮的旋转与按压。首次开启会自动部署独立旋钮映射。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("硬件自检", systemImage: "wrench.and.screwdriver")
        }
    }

    private func selfTestKeyCell(row: Int, col: Int) -> some View {
        let index = row * 5 + col
        let role = CodexPetThemeBuilder.physicalLayout()[index].role
        let count = deck.hardwareSelfTest.keyCount(row: row, col: col)
        return VStack(spacing: 2) {
            Text("K\(index + 1)")
                .font(.caption2.weight(.bold).monospacedDigit())
            Text(role.title)
                .font(.system(size: 8))
                .lineLimit(1)
            Text("×\(count)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(count > 0 ? Color.green : Color.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(
            count > 0 ? Color.green.opacity(0.14) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(count > 0 ? Color.green.opacity(0.55) : Color.clear, lineWidth: 1)
        }
    }

    private func selfTestEncoderCell(_ control: MK20EncoderControl) -> some View {
        let count = deck.hardwareSelfTest.encoderCount(control)
        return VStack(spacing: 2) {
            Text(control.shortTitle)
                .font(.caption2.weight(.semibold))
            Text("×\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(count > 0 ? Color.green : Color.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(
            count > 0 ? Color.green.opacity(0.14) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    private var themeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("部署后启用全部 20 个键：6 个会话键，以及快速、审批、新任务、会话导航、复制答复、翻页、项目目录和停止等 14 个动作键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("左旋钮：上会话 / 按压聚焦 / 下会话；右旋钮：上翻 / 按压停止 / 下翻。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("任务完成提示音", isOn: $deck.completionSoundEnabled)
                    .toggleStyle(.switch)

                Text("任务完成后，对应会话键会显示绿色勾选脉冲；打开该会话后自动清除。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    deck.deployTheme()
                } label: {
                    Label("生成并部署主题", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!deck.mk20Connected || deck.isDeployingTheme)

                if deck.isDeployingTheme {
                    ProgressView(value: deck.themeUploadProgress) {
                        Text("上传中 \(Int(deck.themeUploadProgress * 100))%")
                            .font(.caption2.monospacedDigit())
                    }
                } else if deck.themeUploadProgress >= 1 {
                    Label("主题已部署并请求重载", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                Text("副屏五行由 cmd=1 实时推送(随 tail 事件); 键帽为静态部署。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            Label("主题", systemImage: "paintpalette")
        }
    }

    private var slotCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if deck.slotProjects.allSatisfy({ $0.isEmpty }) {
                    Text("尚无活跃项目 — 跑一个 codex 会话后自动占槽")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(0..<6, id: \.self) { slot in
                        let project = deck.slotProjects.indices.contains(slot) ? deck.slotProjects[slot] : ""
                        if !project.isEmpty {
                            HStack {
                                Circle()
                                    .fill(slotColor(deck.slotStates[slot]))
                                    .frame(width: 8, height: 8)
                                Text(project)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(deck.slotStates[slot].label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("会话槽", systemImage: "rectangle.grid.2x2")
        }
    }

    private var eventLogCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if deck.eventLog.isEmpty {
                    Text("暂无事件").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(deck.eventLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("事件", systemImage: "dot.radiowaves.left.and.right")
        }
    }

    private func slotColor(_ state: PetSlotState) -> Color {
        switch state {
        case .idle: .secondary
        case .working: .blue
        case .needsInput: .orange
        case .done: .green
        case .error: .red
        }
    }
}

/// 单条消息行(角色图标 + 项目徽章 + 文本)。
private struct MessageRow: View {
    let event: CodexTailEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: roleIcon)
                .font(.system(size: 14))
                .foregroundStyle(roleColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.project)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.12), in: Capsule())
                    Text(event.time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                Text(event.text)
                    .font(.callout)
                    .foregroundStyle(event.kind == .agentMessage ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var roleIcon: String {
        switch event.role {
        case .user: "person.fill"
        case .agent: "sparkles"
        case .thinking: "brain.head.profile"
        }
    }

    private var roleColor: Color {
        switch event.role {
        case .user: .blue
        case .agent: .green
        case .thinking: .orange
        }
    }
}
