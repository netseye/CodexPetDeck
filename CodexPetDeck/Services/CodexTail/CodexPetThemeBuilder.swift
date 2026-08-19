import AppKit
import Foundation

/// CodexPet 主题: 把 P4 参考项目的 LVGL 宠物面板布局翻译成 MK20 主题。
///
/// 布局(参考 P4 codex_micro_ui.c 的面板结构 — 深底 + 标题行 + 状态点 +
/// 六槽色带 + 消息气泡, 只取布局思想, 代码独立实现):
///
///   副屏 428×142:
///     [0]  会话行   CpS  "#2 project · 运行中"     (cmd=1 实时)
///     [1]  事件行   CpB  "20:15 工具 · 正在编译"   (cmd=1 实时)
///     [2]  总览行   CpP  "6会话 · 2运行 · HID✓"    (cmd=1 实时)
///     [3]  用量行   CpU  "tokens 33.1B"            (cmd=1 实时)
///     [4]  额度行   CpR  主/次额度与重置时间          (cmd=1 实时)
///     [5]  进度条   CpQ  主额度剩余(0-100)           (cmd=1 实时, type-102)
///
///   键格 4×5:
///     row0: AG00 AG01 AG02 AG03 AG04
///     row1: AG05 ACT06快速 ACT07接受 ACT08拒绝 ACT09分支
///     row2: 语音 新任务 上会话 下会话 复制答复
///     row3: 聚焦 上翻 项目目录 下翻 停止
///
///   旋钮: 左 = 上一会话/聚焦/下一会话, 右 = 上翻/停止/下翻。
///
/// 实时性策略与 CodexDeck 相同: 键帽是慢路(主题重载, 数秒+闪屏, 仅部署时
/// 一次), 副屏五行是快路(cmd=1, 0.5s 随 tail 事件推送)。
enum CodexPetThemeBuilder {
    /// Increment when the serialized device-side key/action layout changes.
    /// The companion deploys each revision once per signed app identity.
    static let themeRevision = 6

    // MARK: - 副屏系统数据键名(宿主 cmd=1 推什么名, 设备就显示什么)

    static let statusKey = "CpS"   // 顶部状态行
    static let bubbleKey = "CpB"   // 气泡(最近事件)
    static let projectKey = "CpP"  // 项目+槽状态行
    static let usageKey = "CpU"    // token 用量行
    static let quotaDetailKey = "CpR" // 主/次额度与重置时间
    static let quotaKey = "CpQ"    // 额度进度条(数值 0-100)

    /// 槽状态行(如后续扩展多行)。当前合并进 projectKey 行。
    static func slotKey(_ slot: Int) -> String { "Cp\(slot)" }

    /// MK20 键格坐标 → CodexPet 语义键。
    static func physicalLayout() -> [(row: Int, col: Int, role: PetKeyRole)] {
        [
            (0, 0, .session(0)), (0, 1, .session(1)), (0, 2, .session(2)),
            (0, 3, .session(3)), (0, 4, .session(4)),
            (1, 0, .session(5)),
            (1, 1, .action(.quick)),
            (1, 2, .action(.accept)),
            (1, 3, .action(.reject)),
            (1, 4, .action(.branch)),
            (2, 0, .action(.voice)),
            (2, 1, .action(.newTask)),
            (2, 2, .action(.previousSession)),
            (2, 3, .action(.nextSession)),
            (2, 4, .action(.copyLastReply)),
            (3, 0, .action(.focusCodex)),
            (3, 1, .action(.scrollUp)),
            // Physical K18 has intermittently emitted both adjacent K17 and
            // K19 usages on the test unit. Keep the essential scroll-down
            // action on verified-stable K19 and move the lower-frequency
            // project shortcut onto K18 as a visible hardware workaround.
            (3, 2, .action(.openProject)),
            (3, 3, .action(.scrollDown)),
            (3, 4, .action(.stopTask)),
        ]
    }

    /// 副屏深色渐变背景(1126×142 → 实际 428×142, P4 面板同款深蓝底)。
    static func renderPanelBackground() -> Data {
        let size = CGSize(width: 428, height: 142)
        let image = NSImage(size: size)
        image.lockFocus()
        let colors = [
            NSColor(calibratedRed: 0.067, green: 0.094, blue: 0.153, alpha: 1),  // #111827
            NSColor(calibratedRed: 0.118, green: 0.161, blue: 0.231, alpha: 1),  // #1E293B
        ]
        let gradient = NSGradient(colors: colors)!
        gradient.draw(
            in: NSRect(origin: .zero, size: size),
            angle: 0
        )
        // 细边框(P4 面板 #334155 描边)
        NSColor(calibratedRed: 0.2, green: 0.255, blue: 0.333, alpha: 1).setStroke()
        let border = NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1))
        border.lineWidth = 1
        border.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

/// CodexPet 键语义。
enum PetKeyRole: Equatable {
    case session(Int)      // 会话槽(聚焦/选择项目)
    case action(PetAction)
}

enum PetAction: Int, CaseIterable, Identifiable {
    case quick = 0   // ACT06
    case accept = 1  // ACT07
    case reject = 2  // ACT08
    case branch = 3  // ACT09
    case voice = 4   // ACT10
    case newTask = 5
    case previousSession = 6
    case nextSession = 7
    case copyLastReply = 8
    case focusCodex = 9
    case scrollUp = 10
    case scrollDown = 11
    case openProject = 12
    case stopTask = 13

    var id: Int { rawValue }

    /// ACT06...ACT10 与 Codex Micro 保持一致；ACT11...ACT19 是本项目的
    /// 桌面直连扩展键名，仅用于日志与诊断。
    var hidKey: String { String(format: "ACT%02d", rawValue + 6) }

    var title: String {
        switch self {
        case .quick: "⚡ 快速"
        case .accept: "✓ 接受"
        case .reject: "✕ 拒绝"
        case .branch: "⑂ 分支"
        case .voice: "◉ 语音"
        case .newTask: "＋ 新任务"
        case .previousSession: "‹ 上会话"
        case .nextSession: "› 下会话"
        case .copyLastReply: "⧉ 复制答复"
        case .focusCodex: "◎ 聚焦"
        case .scrollUp: "↑ 上翻"
        case .scrollDown: "↓ 下翻"
        case .openProject: "▣ 项目目录"
        case .stopTask: "■ 停止"
        }
    }

    var keyTitle: String {
        switch self {
        case .quick: "快速"
        case .accept: "接受"
        case .reject: "拒绝"
        case .branch: "分支"
        case .voice: "语音"
        case .newTask: "新任务"
        case .previousSession: "上会话"
        case .nextSession: "下会话"
        case .copyLastReply: "复制答复"
        case .focusCodex: "聚焦"
        case .scrollUp: "上翻"
        case .scrollDown: "下翻"
        case .openProject: "项目目录"
        case .stopTask: "停止"
        }
    }

    var symbolName: String {
        switch self {
        case .quick: "bolt.fill"
        case .accept: "checkmark.circle.fill"
        case .reject: "xmark.circle.fill"
        case .branch: "arrow.triangle.branch"
        case .voice: "waveform.circle.fill"
        case .newTask: "square.and.pencil"
        case .previousSession: "chevron.left.circle.fill"
        case .nextSession: "chevron.right.circle.fill"
        case .copyLastReply: "doc.on.doc.fill"
        case .focusCodex: "scope"
        case .scrollUp: "arrow.up.circle.fill"
        case .scrollDown: "arrow.down.circle.fill"
        case .openProject: "folder.fill"
        case .stopTask: "stop.circle.fill"
        }
    }

    var tint: NSColorLike {
        switch self {
        case .quick: NSColorLike(r: 245, g: 158, b: 11)
        case .accept: NSColorLike(r: 34, g: 197, b: 94)
        case .reject, .stopTask: NSColorLike(r: 239, g: 68, b: 68)
        case .branch, .newTask: NSColorLike(r: 168, g: 85, b: 247)
        case .voice: NSColorLike(r: 6, g: 182, b: 212)
        case .previousSession, .nextSession, .focusCodex:
            NSColorLike(r: 59, g: 130, b: 246)
        case .copyLastReply, .openProject: NSColorLike(r: 20, g: 184, b: 166)
        case .scrollUp, .scrollDown: NSColorLike(r: 100, g: 116, b: 139)
        }
    }
}

extension PetKeyRole {
    var hidKey: String {
        switch self {
        case .session(let slot): CodexMicroProtocol.Keys.agent[slot]
        case .action(let action): action.hidKey
        }
    }

    var title: String {
        switch self {
        case .session(let slot): "会话 \(slot + 1)"
        case .action(let action): action.title
        }
    }
}

/// 会话槽状态 → 键帽色(P4 线程默认色板同源: blue/violet/pink/orange/green/cyan)。
enum PetPalette {
    static let slotColors: [NSColorLike] = [
        NSColorLike(r: 0x25, g: 0x63, b: 0xEB),  // blue-600
        NSColorLike(r: 0x7C, g: 0x3A, b: 0xED),  // violet-600
        NSColorLike(r: 0xDB, g: 0x27, b: 0x77),  // pink-600
        NSColorLike(r: 0xEA, g: 0x58, b: 0x0C),  // orange-600
        NSColorLike(r: 0x16, g: 0xA3, b: 0x4A),  // green-600
        NSColorLike(r: 0x08, g: 0x91, b: 0xB2),  // cyan-600
    ]

    static let stateColors: [PetSlotState: NSColorLike] = [
        .idle: NSColorLike(r: 30, g: 41, b: 59),       // slate-800
        .working: NSColorLike(r: 59, g: 130, b: 246),  // blue-500
        .needsInput: NSColorLike(r: 245, g: 158, b: 11), // amber-500
        .done: NSColorLike(r: 34, g: 197, b: 94),      // green-500
        .error: NSColorLike(r: 239, g: 68, b: 68),     // red-500
    ]

    /// 会话槽键帽色 = 状态色优先, idle 时用槽位固定色(与 P4 线程色带一致 —
    /// 槽位身份可见, 不依赖状态)。
    static func slotTint(_ slot: Int, state: PetSlotState) -> NSColorLike {
        if state != .idle, let tint = stateColors[state] { return tint }
        return slotColors.indices.contains(slot) ? slotColors[slot] : slotColors[0]
    }
}

struct NSColorLike: Equatable {
    var r: Int, g: Int, b: Int
}

/// 生成 CodexPet .Theme。
enum CodexPetThemeFactory {
    static func buildThemeData(
        slotStates: [PetSlotState],
        projectNames: [String],
        completionAttentionSlots: Set<Int> = []
    ) throws -> Data {
        let builder = ThemeBuilder(themeName: "CodexPet")
        _ = builder.addPage { page in
            // 副屏背景: 深蓝渐变(type-114, 副屏背景唯一可靠类型)。
            page.setSecondaryScreenBackground(
                suggestedFileName: "codexpet-panel.png",
                media: CodexPetThemeBuilder.renderPanelBackground()
            )

            // 副屏五行文本 + 一条进度条(全部绑 system_data, cmd=1 实时推)。
            // 副屏在 640px 画布中的物理范围是 x=106...533。左右各留 8px，
            // 使用完整 412px 内容宽度，避免旧版仅用 330px 导致右侧大块留白。
            _ = page.addWidget(.text, x: 114, y: 4) {
                _ = $0.setSize(412, 20)
                    .placeOnSecondaryScreen()
                    .setZ(3)
                    .bind(systemData: CodexPetThemeBuilder.statusKey, min: 0, max: 0)
                    .text(content: "CodexPet",
                          font: .init(family: "Microsoft YaHei", size: 15),
                          color: WidgetColor(r: 148, g: 163, b: 184))
            }
            _ = page.addWidget(.text, x: 114, y: 26) {
                _ = $0.setSize(412, 22)
                    .placeOnSecondaryScreen()
                    .setZ(3)
                    .bind(systemData: CodexPetThemeBuilder.bubbleKey, min: 0, max: 0)
                    .text(content: "等待事件…",
                          font: .init(family: "Microsoft YaHei", size: 15),
                          color: .white)
            }
            _ = page.addWidget(.text, x: 114, y: 51) {
                _ = $0.setSize(412, 20)
                    .placeOnSecondaryScreen()
                    .setZ(3)
                    .bind(systemData: CodexPetThemeBuilder.projectKey, min: 0, max: 0)
                    .text(content: "—",
                          font: .init(family: "Microsoft YaHei", size: 13),
                          color: WidgetColor(r: 148, g: 163, b: 184))
            }
            _ = page.addWidget(.text, x: 114, y: 75) {
                _ = $0.setSize(412, 20)
                    .placeOnSecondaryScreen()
                    .setZ(3)
                    .bind(systemData: CodexPetThemeBuilder.usageKey, min: 0, max: 0)
                    .text(content: "tokens —",
                          font: .init(family: "Microsoft YaHei", size: 13),
                          color: WidgetColor(r: 125, g: 211, b: 252))
            }
            _ = page.addWidget(.text, x: 114, y: 98) {
                _ = $0.setSize(412, 18)
                    .placeOnSecondaryScreen()
                    .setZ(3)
                    .bind(systemData: CodexPetThemeBuilder.quotaDetailKey, min: 0, max: 0)
                    .text(content: "额度 —",
                          font: .init(family: "Microsoft YaHei", size: 12),
                          color: WidgetColor(r: 196, g: 181, b: 253))
            }
            _ = page.addWidget(.progressBar, x: 114, y: 121) {
                _ = $0.setSize(412, 11)
                    .placeOnSecondaryScreen()
                    .setZ(3)
                    .bind(systemData: CodexPetThemeBuilder.quotaKey, min: 0, max: 100)
                    .barColors(
                        front: WidgetColor(r: 56, g: 189, b: 248),  // sky-400
                        back: WidgetColor(r: 30, g: 41, b: 59),      // slate-800
                        border: WidgetColor(r: 51, g: 65, b: 85),    // slate-700
                        borderWidth: 1, cornerRadius: 6
                    )
            }

            // 键格必须绑定 keyboard controlData。SYK 只有读到主题里的 keyboard
            // 动作才会发出 Ctrl+Alt+QWERT/ASDFG；旧版 action=nil 时 HIDWatcher
            // 虽在监听，但设备根本不会产生这些组合键。
            for (index, entry) in CodexPetThemeBuilder.physicalLayout().enumerated() {
                let (row, col, role) = entry
                let state: PetSlotState
                if case .session(let slot) = role {
                    state = slotStates.indices.contains(slot) ? slotStates[slot] : .idle
                } else {
                    state = .idle
                }
                let tint: NSColorLike
                if case .session(let slot) = role {
                    tint = PetPalette.slotTint(slot, state: state)
                } else if case .action(let action) = role {
                    tint = action.tint
                } else {
                    tint = NSColorLike(r: 51, g: 65, b: 85)  // slate-700
                }
                let title: String
                if case .session(let slot) = role {
                    let fallback = "会话 \(slot + 1)"
                    let name = projectNames.indices.contains(slot) ? projectNames[slot] : ""
                    title = name.isEmpty ? fallback : CodexSessionParser.shorten(name, limit: 8)
                } else {
                    if case .action(let action) = role {
                        title = action.keyTitle
                    } else {
                        title = role.title
                    }
                }
                let key = page.addKey(
                    row: row, column: col,
                    action: keyAction(index: index, role: role),
                    // 标题已经烘焙进 128×128 PNG。主题 title 留空，避免固件
                    // 再绘制一次形成照片中“会话 1 / 重看”等文字重影。
                    title: ""
                )
                if case .session(let slot) = role,
                   completionAttentionSlots.contains(slot) {
                    do {
                        try key.animatedIcon(
                            suggestedFolderName: "cp-session\(slot)-complete",
                            framePNGs: PetIconRenderer.renderCompletionFrames(title: title),
                            delaysMilliseconds: [100, 120, 140, 180, 2_400]
                        )
                    } catch {
                        key.icon(
                            suggestedFileName: iconName(role),
                            imageData: PetIconRenderer.render(
                                symbol: symbol(role), title: title, tint: tint
                            )
                        )
                    }
                } else {
                    key.icon(
                        suggestedFileName: iconName(role),
                        imageData: PetIconRenderer.render(
                            symbol: symbol(role), title: title, tint: tint
                        )
                    )
                }
            }

            // 左旋钮：上会话 / 聚焦 / 下会话；右旋钮：上翻 / 停止 / 下翻。
            // 六个旋钮输入使用独立的 Ctrl+Alt+1...6，不能与屏幕动作键
            // 复用，否则硬件自检无法判断事件究竟来自键格还是旋钮。
            page.addEncoder(
                side: .left,
                action: encoderAction(
                    left: .leftCounterClockwise,
                    middle: .leftPress,
                    right: .leftClockwise
                )
            )
            page.addEncoder(
                side: .right,
                action: encoderAction(
                    left: .rightCounterClockwise,
                    middle: .rightPress,
                    right: .rightClockwise
                )
            )
        }
        return try ThemeFileCodec.encode(builder.build())
    }

    private static func keyAction(index: Int, role: PetKeyRole) -> KeyAction? {
        // The official MK20 default theme assigns physical K18 a standalone
        // left-Shift modifier (keycode 0x0200, keyString "L Shift "). Reuse that
        // firmware-verified lane exactly; the host interprets its HID usage as
        // K18 instead of exposing it as a regular modifier shortcut.
        if role == .action(.openProject) {
            return .keyboard(keycode: 0x0200, keyString: "L Shift ")
        }
        let keycode = PetKeyCodes.themeKeycode(index: index)
        guard keycode != 0 else { return nil }
        return .keyboard(keycode: keycode, keyString: nil)
    }

    private static func encoderAction(
        left: MK20EncoderControl,
        middle: MK20EncoderControl,
        right: MK20EncoderControl
    ) -> KeyAction {
        .encoderKeyboard(
            left: PetKeyCodes.encoderThemeKeycode(for: left), leftLabel: left.action.keyTitle,
            middle: PetKeyCodes.encoderThemeKeycode(for: middle), middleLabel: middle.action.keyTitle,
            right: PetKeyCodes.encoderThemeKeycode(for: right), rightLabel: right.action.keyTitle
        )
    }

    static func iconName(_ role: PetKeyRole) -> String {
        switch role {
        case .session(let slot): "cp-session\(slot).png"
        case .action(let action): "cp-\(action.rawValue).png"
        }
    }

    static func symbol(_ role: PetKeyRole) -> String {
        switch role {
        case .session: "circle.grid.2x2.fill"
        case .action(let action): action.symbolName
        }
    }
}

/// SF Symbol → 128×128 键帽 PNG(与 ScreenKeySwiftUI SFSymbolIconRenderer 同
/// 实现思路 — 该文件为本系列工程自有代码, 复用无许可问题)。
enum PetIconRenderer {
    static func renderCompletionFrames(title: String) -> [Data] {
        let colors = [
            NSColorLike(r: 22, g: 101, b: 52),
            NSColorLike(r: 22, g: 163, b: 74),
            NSColorLike(r: 34, g: 197, b: 94),
            NSColorLike(r: 74, g: 222, b: 128),
        ]
        var frames = [render(
            symbol: "circle.grid.2x2.fill",
            title: title,
            tint: colors[0]
        )]
        frames.append(contentsOf: colors.dropFirst().map {
            render(symbol: "checkmark.circle.fill", title: title, tint: $0)
        })
        frames.append(render(
            symbol: "checkmark.circle.fill",
            title: title,
            tint: NSColorLike(r: 34, g: 197, b: 94)
        ))
        return frames
    }

    static func render(symbol: String, title: String, tint: NSColorLike) -> Data {
        let size = CGSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()

        // 深色底(P4 面板同款 #111827)
        NSColor(calibratedRed: 0.067, green: 0.094, blue: 0.153, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let color = NSColor(
            calibratedRed: CGFloat(tint.r) / 255,
            green: CGFloat(tint.g) / 255,
            blue: CGFloat(tint.b) / 255, alpha: 1
        )

        if let baseSymbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let symbolSize = CGSize(width: 56, height: 56)
            let symbolRect = NSRect(
                x: (size.width - symbolSize.width) / 2,
                y: 52, width: symbolSize.width, height: symbolSize.height
            )
            let tinted = baseSymbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 44, weight: .medium)
            )?.copy() as? NSImage
            tinted?.lockFocus()
            color.set()
            NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
            tinted?.unlockFocus()
            tinted?.draw(in: symbolRect)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let textSize = text.size()
        text.draw(in: NSRect(x: 4, y: 14, width: size.width - 8, height: textSize.height))

        // ⚠ tiffRepresentation 必须在 unlockFocus 之后(lockFocus 中取 tiff 是坏数据)。
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
