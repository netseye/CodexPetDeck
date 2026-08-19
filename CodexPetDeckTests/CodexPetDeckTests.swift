import XCTest
@testable import CodexPetDeck

/// Codex 会话 jsonl 解析测试(样本结构来自本机 0.147/0.148 会话实测)。
final class CodexSessionParserTests: XCTestCase {
    private func parse(_ line: String) -> CodexTailEvent? {
        CodexSessionParser.parse(line: line, project: "mk20")
    }

    func testUserMessage() {
        let line = #"{"timestamp":"2026-08-18T05:26:40.095Z","type":"event_msg","payload":{"type":"user_message","message":"帮我修一下\n第二行"}}"#
        let event = parse(line)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.kind, .userMessage)
        XCTAssertEqual(event?.text, "帮我修一下")
        XCTAssertEqual(event?.role, .user)
        XCTAssertEqual(event?.project, "mk20")
    }

    func testTaskLifecycle() {
        let start = #"{"timestamp":"2026-08-18T05:26:41.000Z","type":"event_msg","payload":{"type":"task_started"}}"#
        let done = #"{"timestamp":"2026-08-18T05:30:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#
        XCTAssertEqual(parse(start)?.kind, .taskStarted)
        XCTAssertEqual(parse(done)?.kind, .taskComplete)
    }

    func testAgentMessageStripsModelDecl() {
        let line = #"{"type":"event_msg","payload":{"type":"agent_message","message":"模型名称: gpt-5\n核心架构: x\n最新修订: 1\n\n这是正文"}}"#
        let event = parse(line)
        XCTAssertEqual(event?.kind, .agentMessage)
        XCTAssertEqual(event?.text, "这是正文")
    }

    func testResponseItemMessage() {
        let line = #"{"timestamp":"2026-08-18T05:31:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"回复正文"}]}}"#
        let event = parse(line)
        XCTAssertEqual(event?.kind, .agentMessage)
        XCTAssertEqual(event?.text, "回复正文")
    }

    func testReasoningAndFunctionCall() {
        let reasoning = #"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#
        let call = #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":\"git status\"}"}}"#
        XCTAssertEqual(parse(reasoning)?.kind, .reasoning)
        let callEvent = parse(call)
        XCTAssertEqual(callEvent?.kind, .functionCall)
        XCTAssertEqual(callEvent?.text, "正在检查工程状态")
    }

    func testFunctionCallOutput() {
        let line = #"{"type":"response_item","payload":{"type":"function_call_output","output":"Exit code: 0\nall good"}}"#
        let event = parse(line)
        XCTAssertEqual(event?.kind, .toolResult)
        XCTAssertTrue(event?.text.hasPrefix("Exit code: 0") == true)
    }

    func testTokenCountFull() {
        let line = """
        {"timestamp":"2026-08-18T05:49:59.362Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":685782}},"rate_limits":{"primary":{"used_percent":92.0,"window_minutes":10080,"resets_at":1787196678},"secondary":null}}}
        """
        let event = parse(line)
        XCTAssertEqual(event?.kind, .tokenCount)
        XCTAssertEqual(event?.totalTokens, 685_782)
        XCTAssertEqual(event?.primaryPercent, 8)
        XCTAssertEqual(event?.primaryLabel, "1 周剩余")
        XCTAssertEqual(event?.primaryAvailable, true)
        XCTAssertEqual(event?.secondaryAvailable, false)
    }

    func testTokenCountMissingLimits() {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
        let event = parse(line)
        XCTAssertEqual(event?.totalTokens, 100)
        XCTAssertEqual(event?.primaryAvailable, false)
        XCTAssertEqual(event?.primaryPercent, nil)
    }

    func testIgnoredLines() {
        XCTAssertNil(parse(#"{"type":"session_meta","payload":{"cwd":"/tmp"}}"#))
        XCTAssertNil(parse(#"{"type":"event_msg","payload":{"type":"thread_settings_applied"}}"#))
        XCTAssertNil(parse(#"{"type":"turn_context","payload":{"cwd":"/tmp"}}"#))
        XCTAssertNil(parse("not json"))
    }

    func testRolloutTimestamp() {
        XCTAssertEqual(
            CodexSessionParser.rolloutTimestamp("rollout-2026-08-18T13-26-39-abc.jsonl"),
            "2026-08-18T13-26-39"
        )
        XCTAssertNil(CodexSessionParser.rolloutTimestamp("other.jsonl"))
    }

    func testSessionMetaIncludesThreadIDAndFiltersSubagent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let primary = root.appendingPathComponent(
            "rollout-2026-08-18T13-26-39-01a0011f-a4d7-7981-9824-86eb5e972772.jsonl"
        )
        let subagent = root.appendingPathComponent(
            "rollout-2026-08-18T13-27-39-01a01457-771f-7122-bed4-9a844b5d1fb8.jsonl"
        )
        try Data((#"{"type":"session_meta","payload":{"id":"01a0011f-a4d7-7981-9824-86eb5e972772","cwd":"/tmp/main","source":"vscode"}}"# + "\n").utf8).write(to: primary)
        try Data((#"{"type":"session_meta","payload":{"id":"01a01457-771f-7122-bed4-9a844b5d1fb8","cwd":"/tmp/main","source":{"subagent":{"other":"guardian"}}}}"# + "\n").utf8).write(to: subagent)

        let sessions = CodexSessionParser.recentSessions(root: root)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.threadID, "01a0011f-a4d7-7981-9824-86eb5e972772")
        XCTAssertEqual(sessions.first?.project, "main")
    }

    func testShorten() {
        XCTAssertEqual(CodexSessionParser.shorten("abc", limit: 5), "abc")
        let long = String(repeating: "a", count: 20)
        let cut = CodexSessionParser.shorten(long, limit: 10)
        XCTAssertEqual(cut.count, 10)
        XCTAssertTrue(cut.hasSuffix("…"))
    }
}

/// 用量格式化。
final class UsageFormatTests: XCTestCase {
    func testFormatTokens() {
        XCTAssertEqual(PetDeckViewModel.formatTokens(999), "999")
        XCTAssertEqual(PetDeckViewModel.formatTokens(1_500), "1.5k")
        XCTAssertEqual(PetDeckViewModel.formatTokens(2_600_000), "2.6M")
        XCTAssertEqual(PetDeckViewModel.formatTokens(33_135_310_977), "33.1B")
    }
}

/// 生产版本必须固定使用原厂 CDC + 独立物理 HID，防止后续重构重新开启
/// 303A:8360 gadget 自动安装并再次改写 MK20 启动脚本。
final class MK20USBPolicyTests: XCTestCase {
    func testCustomGadgetInstallationRemainsDisabled() {
        XCTAssertFalse(MK20USBPolicy.customGadgetInstallEnabled)
        XCTAssertEqual(MK20USBPolicy.stableModeLabel, "原厂 CDC + 物理 HID")
    }
}

/// 左右旋钮分别限频；同一旋钮的方向反转也属于同一机械脉冲簇。
final class EncoderPulseGateTests: XCTestCase {
    func testProductionWindowsMatchMeasuredMK20PulseClusters() {
        var gate = EncoderPulseGate()

        XCTAssertTrue(gate.shouldAccept(.previousSession, at: 1.00))
        XCTAssertFalse(gate.shouldAccept(.nextSession, at: 1.50))
        XCTAssertTrue(gate.shouldAccept(.nextSession, at: 1.66))

        XCTAssertTrue(gate.shouldAccept(.scrollUp, at: 10.00))
        XCTAssertFalse(gate.shouldAccept(.scrollUp, at: 12.40))
        XCTAssertFalse(gate.shouldAccept(.scrollDown, at: 12.49))
        XCTAssertTrue(gate.shouldAccept(.scrollDown, at: 12.51))
    }

    func testCoalescesPulseClusterPerEncoder() {
        var gate = EncoderPulseGate(minimumInterval: 0.22)

        XCTAssertTrue(gate.shouldAccept(.previousSession, at: 10.00))
        XCTAssertFalse(gate.shouldAccept(.previousSession, at: 10.05))
        XCTAssertFalse(gate.shouldAccept(.nextSession, at: 10.12))
        XCTAssertTrue(gate.shouldAccept(.nextSession, at: 10.22))

        // 右旋钮是独立通道，不会被左旋钮的冷却时间误伤。
        XCTAssertTrue(gate.shouldAccept(.scrollUp, at: 10.05))
        XCTAssertFalse(gate.shouldAccept(.scrollDown, at: 10.18))
        XCTAssertTrue(gate.shouldAccept(.scrollDown, at: 10.28))
    }

    func testDoesNotThrottleButtonsOrEncoderPresses() {
        var gate = EncoderPulseGate(minimumInterval: 0.22)

        XCTAssertTrue(gate.shouldAccept(.quick, at: 20.00))
        XCTAssertTrue(gate.shouldAccept(.quick, at: 20.01))
        XCTAssertTrue(gate.shouldAccept(.focusCodex, at: 20.00))
        XCTAssertTrue(gate.shouldAccept(.stopTask, at: 20.01))
    }
}

final class HardwareSelfTestStateTests: XCTestCase {
    func testRecordsCoverageAndReset() {
        var state = HardwareSelfTestState()
        state.start()

        XCTAssertTrue(state.isEnabled)
        state.recordKey(row: 0, col: 0, role: .session(0))
        state.recordKey(row: 0, col: 0, role: .session(0))
        state.recordKey(row: 3, col: 4, role: .action(.stopTask))
        state.recordEncoder(.leftPress)

        XCTAssertEqual(state.keyCount(row: 0, col: 0), 2)
        XCTAssertEqual(state.keyCount(row: 3, col: 4), 1)
        XCTAssertEqual(state.encoderCount(.leftPress), 1)
        XCTAssertEqual(state.testedKeyCount, 2)
        XCTAssertEqual(state.testedEncoderCount, 1)
        XCTAssertEqual(state.testedComponentCount, 3)
        XCTAssertEqual(state.totalPressCount, 4)
        XCTAssertEqual(state.coveragePercent, 11)
        XCTAssertEqual(state.lastEvent, "左旋钮按压")

        state.reset()
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.testedComponentCount, 0)
        XCTAssertEqual(state.totalPressCount, 0)

        state.stop()
        XCTAssertFalse(state.isEnabled)
    }

    func testRejectsOutOfBoundsKeyCoordinate() {
        var state = HardwareSelfTestState()
        state.start()
        state.recordKey(row: 9, col: 9, role: .session(0))
        XCTAssertEqual(state.totalPressCount, 0)
    }
}

/// MK20 V2 连接与文件命令依赖的底层帧/Qt 字典回归测试。
final class MK20ProtocolTests: XCTestCase {
    func testV2FrameRoundTripAcrossPartialReads() {
        let payload = Data("{\"connect\":true}".utf8)
        let frame = V2PacketEncoder().encode(command: .sendJSON, payload: payload)
        let parser = V2PacketParser()

        XCTAssertTrue(parser.append(frame.prefix(17)).isEmpty)
        let packets = parser.append(frame.dropFirst(17))
        XCTAssertEqual(packets, [V2Packet(id: 0, command: V2Command.sendJSON.rawValue, payload: payload)])
    }

    func testDecodesRealMK20V230FindDevicePayload() throws {
        let payload = try XCTUnwrap(Data(base64Encoded:
            "AAAACAAAAA4AdgBlAHIAcwBpAG8AbgAAAAoAVgAyAC4AMwAwAAAAKgB1AHAAZwByAGEAZABlAFQAbwBMAGEAdABlAHMAdABNAGUAdABoAG8AZAAAAAIAMQAAABgAcwBjAHIAZQBlAG4AXwB3AGkAZAB0AGgAAAAGADYANAAwAAAAGABzAGMAcgBlAGUAbgBfAG0AbwBkAGUAbAAAAAgATQBLADIAMAAAABoAcwBjAHIAZQBlAG4AXwBoAGUAaQBnAGgAdAAAAAYANgA1ADYAAAAYAGQAZQB2AGkAYwBlAFYAbwBsAHUAbQBlAAAAAgA3AAAAFABkAGUAdgBpAGMAZQBOAGEAbQBlAAAAEgBTAGMAcgBlAGUAbgBLAGUAeQAAABAAZABlAHYAaQBjAGUAQgBsAAAABAA2ADA="
        ))

        let values = try QtDataStream.decodeStringMap(payload)
        XCTAssertEqual(values["screen_model"], "MK20")
        XCTAssertEqual(values["version"], "V2.30")
        XCTAssertEqual(values["screen_width"], "640")
        XCTAssertEqual(values["screen_height"], "656")
    }

    func testFileCommandContainsPathAndSize() throws {
        let path = "/data/theme/MK20/CodexPet.Theme"
        let frame = V2PacketEncoder().encodeFileCommand(.fileStart, path: path, value: "123456")
        let packet = try XCTUnwrap(V2PacketParser().append(frame).first)
        XCTAssertEqual(packet.command, V2Command.fileStart.rawValue)
        XCTAssertEqual(try QtDataStream.decodeStringMap(packet.payload), [path: "123456"])
    }

    func testSystemDataCommandCarriesRawQtMap() throws {
        let values = ["CpS": "CodexPet · MK20✓", "CpQ": "42"]
        let frame = V2PacketEncoder().encodeSystemData(values)
        let packet = try XCTUnwrap(V2PacketParser().append(frame).first)

        XCTAssertEqual(packet.command, V2Command.sendSystemData.rawValue)
        XCTAssertEqual(packet.payload, QtDataStream.encodeStringMap(values))
        XCTAssertEqual(try QtDataStream.decodeStringMap(packet.payload), values)
        XCTAssertNotEqual(packet.payload, Data(packet.payload.base64EncodedString().utf8))
    }
}

/// 主题生成冒烟(可解码 + 键位/副屏绑定齐)。
final class CodexPetThemeTests: XCTestCase {
    func testBuildThemeDecodable() throws {
        let data = try CodexPetThemeFactory.buildThemeData(
            slotStates: [.working, .done, .idle, .idle, .idle, .idle],
            projectNames: ["mk20", "voice-app", "", "", "", ""]
        )
        XCTAssertGreaterThan(data.count, 1_000)
        // 往返: 能解码说明容器结构合法(真机加载的前置)。
        let theme = try ThemeFileCodec.decode(data)
        XCTAssertTrue(theme.layoutJSON.contains("CodexPet"))
        for key in CodexPetThemeBuilder.panelDataKeys {
            XCTAssertTrue(theme.layoutJSON.contains("\"\(key)\""), "缺绑定 \(key)")
        }

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(theme.layoutJSON.utf8)) as? [String: Any]
        )
        let pages = try XCTUnwrap(root["pages"] as? [[String: Any]])
        let items = try XCTUnwrap(pages.first?["items"] as? [[String: Any]])
        let physicalCoordinates = Set(CodexPetThemeBuilder.physicalLayout().map { "\($0.row),\($0.col)" })
        let deckKeys = items.filter { item in
            guard item["type"] as? String == "115",
                  let row = Int(item["row"] as? String ?? ""),
                  let col = Int(item["col"] as? String ?? "") else { return false }
            return physicalCoordinates.contains("\(row),\(col)")
        }
        XCTAssertEqual(deckKeys.count, 20)
        for key in deckKeys {
            XCTAssertEqual(key["title"] as? String, "", "键帽标题只能由 PNG 绘制一次")
            XCTAssertFalse((key["controlData"] as? String ?? "").isEmpty, "缺少 HID keyboard 动作")
        }

        let scrollDownKey = try XCTUnwrap(deckKeys.first {
            $0["row"] as? String == "3" && $0["col"] as? String == "3"
        })
        let scrollDownIndex = try XCTUnwrap(
            CodexPetThemeBuilder.physicalLayout().firstIndex {
                $0.row == 3 && $0.col == 3 && $0.role == .action(.scrollDown)
            }
        )
        let expectedScrollDown = ThemeControlData.encode(action: .keyboard(
            keycode: PetKeyCodes.themeKeycode(index: scrollDownIndex),
            keyString: nil
        )).base64EncodedString()
        XCTAssertEqual(scrollDownKey["controlData"] as? String, expectedScrollDown)
        XCTAssertEqual(PetKeyCodes.slots[scrollDownIndex].hidUsage, 0x13)

        let projectIndex = try XCTUnwrap(
            CodexPetThemeBuilder.physicalLayout().firstIndex {
                $0.row == 3 && $0.col == 2 && $0.role == .action(.openProject)
            }
        )
        XCTAssertEqual(
            PetKeyCodes.slots[projectIndex].hidUsage,
            PetKeyCodes.officialK18Usage
        )
        let projectKey = try XCTUnwrap(deckKeys.first {
            $0["row"] as? String == "3" && $0["col"] as? String == "2"
        })
        let expectedProject = ThemeControlData.encode(
            action: .keyboard(keycode: 0x0200, keyString: "L Shift ")
        ).base64EncodedString()
        XCTAssertEqual(projectKey["controlData"] as? String, expectedProject)
        XCTAssertEqual(
            expectedProject,
            "AAAABgAAAAgAdAB5AHAAZQAAAAoAAAAAEABrAGUAeQBiAG8AYQByAGQAAAAiAHAAYQByAGUAbgB0AEQAZQBzAGMAcgBpAHAAdABpAG8AbgAAAAoAAAAADHz7ft+Pk1FlY6dSNgAAAA4AawBlAHkAYwBvAGQAZQAAAAIAAAACAAAAABIAawBlAHkAUwB0AHIAaQBuAGcAAAAKAAAAABAATAAgAFMAaABpAGYAdAAgAAAAEABpAGMAbwBuAFAAYQB0AGgAAAAKAAAAADwALwBzAHQAYQB0AGkAYwAvAGkAYwBvAG4ALwBkAGEAcgBrAC8AawBlAHkAYgBvAGEAcgBkAC4AcABuAGcAAAAWAGQAZQBzAGMAcgBpAHAAdABpAG8AbgAAAAoAAAAABJUudtg="
        )

        let statusWidget = items.first { $0["system_data_name"] as? String == CodexPetThemeBuilder.statusKey }
        XCTAssertEqual(statusWidget?["x"] as? String, "114")
        XCTAssertEqual(statusWidget?["w"] as? String, "412")
        XCTAssertEqual(statusWidget?["backgroundType"] as? String, "secondary")
        XCTAssertEqual(statusWidget?["backupX"] as? String, "8")
        XCTAssertEqual(statusWidget?["backupY"] as? String, "4")

        let quotaDetail = items.first {
            $0["system_data_name"] as? String == CodexPetThemeBuilder.quotaDetailKey
        }
        XCTAssertEqual(quotaDetail?["backgroundType"] as? String, "secondary")

        let encoders = items.filter {
            ($0["row"] as? String == "100" && $0["col"] as? String == "100")
                || ($0["row"] as? String == "103" && $0["col"] as? String == "103")
        }
        XCTAssertEqual(encoders.count, 2)
        XCTAssertTrue(encoders.allSatisfy { !($0["controlData"] as? String ?? "").isEmpty })

        let leftEncoder = try XCTUnwrap(encoders.first {
            $0["row"] as? String == "100" && $0["col"] as? String == "100"
        })
        let expectedLeft = ThemeControlData.encode(action: .encoderKeyboard(
            left: PetKeyCodes.encoderThemeKeycode(for: .leftCounterClockwise),
            leftLabel: PetAction.previousSession.keyTitle,
            middle: PetKeyCodes.encoderThemeKeycode(for: .leftPress),
            middleLabel: PetAction.focusCodex.keyTitle,
            right: PetKeyCodes.encoderThemeKeycode(for: .leftClockwise),
            rightLabel: PetAction.nextSession.keyTitle
        )).base64EncodedString()
        XCTAssertEqual(leftEncoder["controlData"] as? String, expectedLeft)

        let rightEncoder = try XCTUnwrap(encoders.first {
            $0["row"] as? String == "103" && $0["col"] as? String == "103"
        })
        let expectedRight = ThemeControlData.encode(action: .encoderKeyboard(
            left: PetKeyCodes.encoderThemeKeycode(for: .rightCounterClockwise),
            leftLabel: PetAction.scrollUp.keyTitle,
            middle: PetKeyCodes.encoderThemeKeycode(for: .rightPress),
            middleLabel: PetAction.stopTask.keyTitle,
            right: PetKeyCodes.encoderThemeKeycode(for: .rightClockwise),
            rightLabel: PetAction.scrollDown.keyTitle
        )).base64EncodedString()
        XCTAssertEqual(rightEncoder["controlData"] as? String, expectedRight)
    }

    func testPhysicalLayoutBounds() {
        let layout = CodexPetThemeBuilder.physicalLayout()
        XCTAssertEqual(layout.count, 20)
        for entry in layout {
            XCTAssertTrue((0..<4).contains(entry.row))
            XCTAssertTrue((0..<5).contains(entry.col))
        }

        let sessions = layout.compactMap { entry -> Int? in
            if case .session(let slot) = entry.role { return slot }
            return nil
        }
        let actions = layout.compactMap { entry -> PetAction? in
            if case .action(let action) = entry.role { return action }
            return nil
        }
        XCTAssertEqual(sessions, Array(0..<6))
        XCTAssertEqual(Set(actions.map(\.rawValue)), Set(PetAction.allCases.map(\.rawValue)))
        XCTAssertEqual(
            Set(actions.map(\.hidKey)),
            Set((6...19).map { String(format: "ACT%02d", $0) })
        )
    }

    func testCompletionAttentionAnimatesOnlyMatchingSessionKey() throws {
        let frames = PetIconRenderer.renderCompletionFrames(title: "voice-app")
        XCTAssertEqual(frames.count, 5)
        XCTAssertTrue(frames.allSatisfy { !$0.isEmpty })

        let data = try CodexPetThemeFactory.buildThemeData(
            slotStates: [.working, .done, .idle, .idle, .idle, .idle],
            projectNames: ["mk20", "voice-app", "", "", "", ""],
            completionAttentionSlots: [1]
        )
        let theme = try ThemeFileCodec.decode(data)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(theme.layoutJSON.utf8)) as? [String: Any]
        )
        let pages = try XCTUnwrap(root["pages"] as? [[String: Any]])
        let items = try XCTUnwrap(pages.first?["items"] as? [[String: Any]])
        let slot1 = try XCTUnwrap(items.first {
            $0["row"] as? String == "0" && $0["col"] as? String == "1"
        })
        let slot0 = try XCTUnwrap(items.first {
            $0["row"] as? String == "0" && $0["col"] as? String == "0"
        })

        XCTAssertEqual(slot1["path"] as? String, "")
        XCTAssertFalse((slot1["paths"] as? String ?? "").isEmpty)
        XCTAssertEqual(slot1["frameDelays"] as? String, "100,120,140,180,2400")
        XCTAssertFalse((slot0["path"] as? String ?? "").isEmpty)
        XCTAssertEqual(slot0["paths"] as? String, "")
    }

    func testKeyCodes() {
        // Ctrl+Alt+Q = (5<<8)|0x14
        XCTAssertEqual(PetKeyCodes.themeKeycode(index: 0), Int32(bitPattern: (5 << 8) | 0x14))
        XCTAssertEqual(PetKeyCodes.themeKeycode(index: 99), 0)
        XCTAssertNotNil(PetKeyCodes.cgLayout[12])  // Q
        XCTAssertNotNil(PetKeyCodes.cgLayout[0])   // A
        XCTAssertNotNil(PetKeyCodes.cgLayout[6])   // Z / ACT10
        XCTAssertEqual(PetKeyCodes.hidLayout[0x1A]?.row, 0) // W / 会话2
        XCTAssertEqual(PetKeyCodes.hidLayout[0x1A]?.col, 1)
        XCTAssertEqual(PetKeyCodes.themeKeycode(index: 10), Int32(bitPattern: (5 << 8) | 0x1D))
        XCTAssertEqual(PetKeyCodes.themeKeycode(index: 19), Int32(bitPattern: (5 << 8) | 0x0F))
        XCTAssertEqual(
            PetKeyCodes.themeKeycode(for: .nextSession),
            PetKeyCodes.themeKeycode(index: 13)
        )
        XCTAssertEqual(PetKeyCodes.hidLayout.count, 20)
        XCTAssertEqual(PetKeyCodes.encoderHIDLayout.count, 6)
        XCTAssertEqual(PetKeyCodes.encoderHIDLayout[0x1E], .leftCounterClockwise)
        XCTAssertEqual(PetKeyCodes.encoderHIDLayout[0x23], .rightClockwise)
        XCTAssertTrue(
            Set(PetKeyCodes.slots.map(\.hidUsage))
                .isDisjoint(with: Set(PetKeyCodes.encoderSlots.map(\.hidUsage)))
        )
        XCTAssertEqual(MK20EncoderControl.leftPress.action, .focusCodex)
        XCTAssertEqual(MK20EncoderControl.rightPress.action, .stopTask)
    }

    func testCodexMicroEmulatorEmitsStandardButtonNotifications() throws {
        let emulator = CodexMicroEmulator()
        var messages: [String] = []
        emulator.onSend = { messages.append($0) }

        emulator.tapAgent(2)
        emulator.tapAction("ACT08")

        XCTAssertEqual(messages.count, 4)
        let agentPress = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(messages[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(agentPress["method"] as? String, "v.oai.hid")
        let agentParams = try XCTUnwrap(agentPress["params"] as? [String: Any])
        XCTAssertEqual(agentParams["k"] as? String, "AG02")
        XCTAssertEqual(agentParams["ag"] as? Int, 2)
        XCTAssertEqual(agentParams["act"] as? Int, 1)

        let actionPress = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(messages[2].utf8)) as? [String: Any]
        )
        let actionParams = try XCTUnwrap(actionPress["params"] as? [String: Any])
        XCTAssertEqual(actionParams["k"] as? String, "ACT08")
        XCTAssertEqual(actionParams["act"] as? Int, 1)
    }
}
