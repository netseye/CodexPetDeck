import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 把 MK20 按键直接翻译成 Codex Desktop 操作。
///
/// 会话键使用 Codex 自己注册的 codex:// 深链；动作键使用 Codex 的公开快捷键，
/// 快速/分支（无默认快捷键）通过辅助功能树点击对应的可访问控件。这里不修改、
/// 注入或重签 Codex.app，也不再要求 MK20 枚举成 Codex Micro USB 设备。
@MainActor
final class CodexDesktopController {
    enum Outcome {
        case performed(String)
        case unavailable(String)
    }

    private static let bundleIdentifier = "com.openai.codex"

    func openThread(_ session: CodexSessionRef) -> Outcome {
        guard let url = URL(string: "codex://threads/\(session.threadID)") else {
            return .unavailable("线程地址无效")
        }
        guard NSWorkspace.shared.open(url) else {
            return .unavailable("Codex 未能打开线程")
        }
        return .performed("已切换到 \(session.project)")
    }

    func perform(_ action: PetAction, completion: @escaping (Outcome) -> Void) {
        guard let application = runningApplication() else {
            completion(.unavailable("Codex Desktop 未运行"))
            return
        }
        // macOS 14 deprecated activateIgnoringOtherApps and ignores it. A
        // normal activation is sufficient before the targeted event path.
        application.activate(options: [])

        switch action {
        case .accept:
            postKey(after: 0.12, keyCode: 36) // Codex approval.approve = Enter
            completion(.performed("已发送批准命令"))
        case .reject:
            postKey(after: 0.12, keyCode: 53) // Codex approval.decline = Escape
            completion(.performed("已发送拒绝命令"))
        case .voice:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self else { return }
                // Codex 26.814: composer.startDictation = Ctrl+Shift+D. 定向投递到
                // Codex PID，避免按键触发时 Codex 尚未成为前台应用而丢失快捷键。
                // 不按标题搜索“听写”菜单，因为 macOS 会向应用菜单注入系统听写项。
                self.postKey(
                    after: 0,
                    keyCode: 2, // D
                    flags: [.maskControl, .maskShift],
                    target: application
                )
                completion(.performed("已向 Codex 定向发送专用语音命令"))
            }
        case .quick:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                let pressed = self.pressFirstElement(
                    in: application,
                    matching: [
                        "enable fast mode", "enable standard mode",
                        "启用快速模式", "启用标准模式",
                    ]
                )
                completion(pressed
                    ? .performed("已切换快速模式")
                    : .unavailable("当前 Codex 窗口未显示快速模式控件"))
            }
        case .branch:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                guard self.pressFirstElement(
                    in: application,
                    matching: ["chat actions", "聊天操作", "会话操作"]
                ) else {
                    completion(.unavailable("未找到 Codex 会话操作菜单"))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self else { return }
                    let pressed = self.pressFirstElement(
                        in: application,
                        matching: [
                            "fork chat in same worktree", "fork chat",
                            "在同一工作树中分支", "分支会话", "创建分支",
                        ]
                    )
                    completion(pressed
                        ? .performed("已创建会话分支")
                        : .unavailable("会话操作菜单中未找到分支命令"))
                }
            }
        case .newTask:
            postKey(after: 0.12, keyCode: 45, flags: [.maskCommand]) // ⌘N
            completion(.performed("已打开新任务"))
        case .focusCodex:
            completion(.performed("已聚焦 Codex Desktop"))
        case .scrollUp:
            postKey(after: 0.12, keyCode: 116) // Page Up
            completion(.performed("会话已向上翻页"))
        case .scrollDown:
            postKey(after: 0.12, keyCode: 121) // Page Down
            completion(.performed("会话已向下翻页"))
        case .stopTask:
            postKey(after: 0.12, keyCode: 53) // Escape
            completion(.performed("已发送停止命令"))
        case .previousSession, .nextSession, .copyLastReply, .openProject:
            completion(.unavailable("该动作应由 CodexPetDeck 宿主处理"))
        }
    }

    private func runningApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).first
    }

    private func postKey(
        after delay: TimeInterval,
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        target application: NSRunningApplication? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .privateState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            down?.flags = flags
            up?.flags = flags
            if let application {
                down?.postToPid(application.processIdentifier)
                up?.postToPid(application.processIdentifier)
            } else {
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    private func pressFirstElement(
        in application: NSRunningApplication,
        matching needles: [String]
    ) -> Bool {
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var queue = [root]
        var index = 0
        while index < queue.count, index < 4_000 {
            let element = queue[index]
            index += 1
            let labels = [
                stringAttribute(kAXTitleAttribute, element),
                stringAttribute(kAXDescriptionAttribute, element),
                stringAttribute(kAXHelpAttribute, element),
                stringAttribute(kAXValueAttribute, element),
            ].compactMap { $0?.lowercased() }
            if needles.contains(where: { needle in
                labels.contains(where: { $0.contains(needle.lowercased()) })
            }), AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return true
            }
            queue.append(contentsOf: children(of: element))
        }
        return false
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ attribute: String, _ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }
}
