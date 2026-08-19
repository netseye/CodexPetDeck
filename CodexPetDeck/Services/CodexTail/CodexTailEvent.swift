import Foundation

/// 从 Codex 会话 jsonl 解析出的、推给 MK20 的协议事件。
///
/// 事件集对齐 Codex Micro 宿主协议的事实(P4 参考项目逆向自官方固件行为,
/// 本文件只对齐协议事实, 实现为独立编写):
/// - task_started / task_complete → 槽状态起落
/// - user_message / agent_message → 消息中心
/// - reasoning / function_call / tool_result → 过程状态气泡
/// - token_count → 副屏用量条(total + primary/secondary 剩余)
struct CodexTailEvent: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case taskStarted = "task_started"
        case taskComplete = "task_complete"
        case userMessage = "user_message"
        case agentMessage = "agent_message"
        case reasoning = "reasoning"
        case functionCall = "function_call"
        case toolResult = "tool_result"
        case tokenCount = "token_count"
    }

    enum Role: String, Equatable {
        case user
        case agent
        case thinking
    }

    var id: String
    var kind: Kind
    var text: String
    /// 本地时间 HH:MM(显示用)。
    var time: String
    /// 项目目录名(会话 cwd 的 lastPathComponent)。
    var project: String
    var role: Role

    // token_count 专有(非 token 事件为 nil/默认)。
    var totalTokens: Int?
    var primaryPercent: Int?
    var secondaryPercent: Int?
    var primaryLabel: String?
    var secondaryLabel: String?
    var primaryReset: String?
    var secondaryReset: String?
    var primaryAvailable: Bool?
    var secondaryAvailable: Bool?

    var isTokenCount: Bool { kind == .tokenCount }
}

/// 会话文件的身份摘要(监听列表条目)。
struct CodexSessionRef: Equatable {
    var path: URL
    /// Codex 桌面端线程 UUID，用于 codex://threads/<id> 深链切换。
    var threadID: String
    /// 文件名里的 rollout 时间戳(排序用)。
    var startedAt: String
    /// 项目名(session_meta.cwd 解析; 解析失败用文件名)。
    var project: String
    var cwd: String

    static func == (l: CodexSessionRef, r: CodexSessionRef) -> Bool { l.path == r.path }
}

/// 会话槽状态(副屏/键帽语义)。
enum PetSlotState: String {
    case idle
    case working
    case needsInput
    case done
    case error

    var label: String {
        switch self {
        case .idle: "空闲"
        case .working: "运行中"
        case .needsInput: "待输入"
        case .done: "已完成"
        case .error: "出错"
        }
    }
}
