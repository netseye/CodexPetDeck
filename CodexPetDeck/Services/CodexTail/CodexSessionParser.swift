import Foundation

/// Codex 会话 jsonl 单行 → CodexTailEvent / 会话元信息。
///
/// jsonl 结构(本机 0.147/0.148 实测):
/// - 每行 {timestamp, type, payload}; type ∈ {session_meta, turn_context,
///   event_msg, response_item, ...}
/// - event_msg.payload.type: user_message / task_started / task_complete /
///   agent_message / token_count / thread_settings_applied / agent_reasoning
/// - response_item.payload.type: message(assistant 正文)/ reasoning /
///   function_call / function_call_output / custom_tool_call
/// - token_count: info.total_token_usage.total_tokens + rate_limits.primary/
///   secondary{used_percent, window_minutes, resets_at}; secondary 可为 null。
///
/// 与 P4 参考(tools/codex_tail.py)对齐的是**协议事实**(哪些事件、字段在哪);
/// 解析实现独立编写(P4 项目无 LICENSE 文件, 不复制其代码)。
enum CodexSessionParser {
    static let sessionNamePattern = try! NSRegularExpression(
        pattern: #"^rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})"#
    )

    // MARK: - 会话发现

    /// sessions 根目录下最近活跃的会话文件(按 mtime 排序, 最多 limit 个)。
    static func recentSessions(root: URL, limit: Int = 6, maxAge: TimeInterval = 12 * 3600) -> [CodexSessionRef] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let now = Date().timeIntervalSince1970
        var candidates: [(ref: CodexSessionRef, mtime: Double)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true, let mtime = values.contentModificationDate?.timeIntervalSince1970,
                  now - mtime <= maxAge else { continue }
            guard let meta = scanSessionMeta(url), !meta.isSubagent else { continue }
            candidates.append((
                CodexSessionRef(
                    path: url,
                    threadID: meta.threadID,
                    startedAt: rolloutTimestamp(url.lastPathComponent) ?? "",
                    project: meta.project,
                    cwd: meta.cwd
                ),
                mtime
            ))
        }
        return candidates
            .sorted { $0.mtime > $1.mtime }
            .prefix(limit)
            .map(\.ref)
    }

    /// 文件名 rollout-YYYY-MM-DDTHH-MM-SS → 原始时间戳串。
    static func rolloutTimestamp(_ fileName: String) -> String? {
        let range = NSRange(fileName.startIndex..., in: fileName)
        guard let match = sessionNamePattern.firstMatch(
            in: fileName, options: [], range: range
        ), match.numberOfRanges > 1,
            let stamp = Range(match.range(at: 1), in: fileName) else { return nil }
        return String(fileName[stamp])
    }

    /// 只扫头部 N 行找 session_meta(整文件可能几十 MB, 不全文读)。
    /// Codex Desktop 会同时产生 guardian 等内部子会话；它们不能显示成可切换任务。
    static func scanSessionMeta(
        _ url: URL,
        maxLines: Int = 40
    ) -> (cwd: String, project: String, threadID: String, isSubagent: Bool)? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }
        var line = Data()
        var lines = 0
        let bufferSize = 64 * 1_024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while lines < maxLines {
            let n = stream.read(&buffer, maxLength: bufferSize)
            guard n > 0 else { break }
            for b in buffer[0..<n] {
                if b == 0x0A {
                    if !line.isEmpty,
                       let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       object["type"] as? String == "session_meta",
                       let payload = object["payload"] as? [String: Any],
                       let cwd = payload["cwd"] as? String, !cwd.isEmpty,
                       let threadID = payload["id"] as? String, !threadID.isEmpty {
                        let source = payload["source"] as? [String: Any]
                        let isSubagent = source?["subagent"] != nil
                            || payload["thread_source"] as? String == "subagent"
                        return (
                            cwd,
                            (cwd as NSString).lastPathComponent,
                            threadID,
                            isSubagent
                        )
                    }
                    line = Data()
                    lines += 1
                    if lines >= maxLines { break }
                } else {
                    line.append(b)
                }
            }
        }
        return nil
    }

    // MARK: - 事件解析

    /// 一行 jsonl → 事件; 非关注行返回 nil。
    /// project 为该会话的项目名(调用方从 session_meta 取得)。
    static func parse(line: String, project: String) -> CodexTailEvent? {
        let data = Data(line.utf8)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = raw["type"] as? String else { return nil }
        let payload = raw["payload"] as? [String: Any]
        let time = timeLabel(raw)
        switch type {
        case "event_msg":
            return parseEventMsg(payload: payload, time: time, project: project, raw: raw)
        case "response_item":
            return parseResponseItem(payload: payload, time: time, project: project, raw: raw)
        default:
            return nil
        }
    }

    private static func parseEventMsg(
        payload: [String: Any]?, time: String, project: String, raw: [String: Any]
    ) -> CodexTailEvent? {
        guard let payload, let kind = payload["type"] as? String else { return nil }
        let eventID = "\(time)-\(stableHash(raw))"
        func make(_ k: CodexTailEvent.Kind, _ text: String, role: CodexTailEvent.Role) -> CodexTailEvent {
            CodexTailEvent(id: eventID, kind: k, text: text, time: time, project: project, role: role)
        }
        switch kind {
        case "user_message":
            let title = firstLineTitle(payload["message"] as? String)
            return make(.userMessage, title, role: .user)
        case "task_started":
            return make(.taskStarted, "任务开始", role: .thinking)
        case "task_complete":
            return make(.taskComplete, "任务完成", role: .thinking)
        case "agent_message":
            let text = cleanAgentMessage(payload["message"] as? String)
            guard !text.isEmpty else { return nil }
            return make(.agentMessage, text, role: .agent)
        case "agent_reasoning":
            return make(.reasoning, "正在思考", role: .thinking)
        case "token_count":
            return parseTokenCount(payload: payload, time: time, project: project, eventID: eventID)
        default:
            return nil // thread_settings_applied 等
        }
    }

    private static func parseResponseItem(
        payload: [String: Any]?, time: String, project: String, raw: [String: Any]
    ) -> CodexTailEvent? {
        guard let payload, let kind = payload["type"] as? String else { return nil }
        let eventID = "\(time)-\(stableHash(raw))"
        func make(_ k: CodexTailEvent.Kind, _ text: String, role: CodexTailEvent.Role) -> CodexTailEvent {
            CodexTailEvent(id: eventID, kind: k, text: text, time: time, project: project, role: role)
        }
        switch kind {
        case "message":
            let text = cleanAgentMessage(messageText(payload))
            guard !text.isEmpty else { return nil }
            return make(.agentMessage, text, role: .agent)
        case "reasoning":
            return make(.reasoning, "正在思考", role: .thinking)
        case "function_call", "custom_tool_call":
            return make(.functionCall, toolCallStatus(payload), role: .thinking)
        case "function_call_output":
            return make(.toolResult, summarizeToolOutput(payload["output"]), role: .thinking)
        default:
            return nil
        }
    }

    // MARK: - token_count

    private static func parseTokenCount(
        payload: [String: Any], time: String, project: String, eventID: String
    ) -> CodexTailEvent {
        var event = CodexTailEvent(
            id: eventID, kind: .tokenCount, text: "", time: time, project: project, role: .thinking
        )
        let info = payload["info"] as? [String: Any]
        let total = info?["total_token_usage"] as? [String: Any]
        event.totalTokens = total?["total_tokens"] as? Int

        let limits = payload["rate_limits"] as? [String: Any]
        if let primary = limits?["primary"] as? [String: Any] {
            event.primaryPercent = remainingPercent(primary)
            event.primaryLabel = quotaLabel(primary)
            event.primaryReset = resetLabel(primary)
            event.primaryAvailable = limitAvailable(primary)
        } else {
            event.primaryAvailable = false
        }
        if let secondary = limits?["secondary"] as? [String: Any] {
            event.secondaryPercent = remainingPercent(secondary)
            event.secondaryLabel = quotaLabel(secondary)
            event.secondaryReset = resetLabel(secondary)
            event.secondaryAvailable = limitAvailable(secondary)
        } else {
            event.secondaryAvailable = false
        }
        return event
    }

    /// 已取消额度返回 null/缺 used_percent — 不能显示成 100%。
    static func limitAvailable(_ limit: [String: Any]) -> Bool {
        (limit["used_percent"] as? Double) != nil || (limit["used_percent"] as? Int) != nil
    }

    static func remainingPercent(_ limit: [String: Any]) -> Int {
        let used: Double
        if let u = limit["used_percent"] as? Double { used = u }
        else if let u = limit["used_percent"] as? Int { used = Double(u) }
        else { return 0 }
        return max(0, min(100, Int((100 - used).rounded())))
    }

    /// 按服务端窗口时长生成标签(周/天/小时)。
    static func quotaLabel(_ limit: [String: Any]) -> String {
        let windowMinutes = (limit["window_minutes"] as? Int) ?? 0
        if windowMinutes <= 0 { return "额度剩余" }
        if windowMinutes.isMultiple(of: 7 * 24 * 60) { return "\(windowMinutes / (7 * 24 * 60)) 周剩余" }
        if windowMinutes.isMultiple(of: 24 * 60) { return "\(windowMinutes / (24 * 60)) 天剩余" }
        if windowMinutes.isMultiple(of: 60) { return "\(windowMinutes / 60) 小时剩余" }
        return "额度剩余"
    }

    static func resetLabel(_ limit: [String: Any]) -> String {
        guard let resetsAt = (limit["resets_at"] as? Int) ?? (limit["resets_at"] as? Double).map(Int.init)
        else { return "--" }
        let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let formatter = DateFormatter()
        let windowMinutes = (limit["window_minutes"] as? Int) ?? 0
        formatter.dateFormat = windowMinutes <= 24 * 60 ? "HH:mm" : "M月d日"
        return formatter.string(from: date)
    }

    // MARK: - 文本清洗

    /// 用户消息 → 任务标题: 第一个非空行, 截 42 字。
    static func firstLineTitle(_ message: String?) -> String {
        guard let message else { return "Codex 任务" }
        for line in message.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return shorten(trimmed, limit: 42) }
        }
        return "Codex 任务"
    }

    /// 去掉 agent 回复开头的模型声明头(如 "模型名称: ..." 三行)。
    static func cleanAgentMessage(_ text: String?) -> String {
        guard var lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map({ String($0) }) as [String]? else { return "" }
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty || isModelDeclLine(first) {
            lines.removeFirst()
            if lines.isEmpty { break }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
    }

    private static let modelDeclPrefixes = ["模型名称", "核心架构", "最新修订"]

    private static func isModelDeclLine(_ line: String) -> Bool {
        let trimmed = line
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-* "))
            .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        return modelDeclPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// response_item.message 的正文(content[].text)。
    static func messageText(_ payload: [String: Any]) -> String {
        guard (payload["role"] as? String) ?? "assistant" == "assistant" else { return "" }
        guard let content = payload["content"] as? [[String: Any]] else {
            return (payload["content"] as? String) ?? ""
        }
        var parts: [String] = []
        for item in content {
            guard let type = item["type"] as? String,
                  type == "output_text" || type == "text",
                  let text = item["text"] as? String, !text.isEmpty else { continue }
            parts.append(text.trimmingCharacters(in: .whitespaces))
        }
        return parts.joined(separator: "\n")
    }

    /// 工具调用 → 短状态文案("正在编辑 xxx.swift")。
    static func toolCallStatus(_ payload: [String: Any]) -> String {
        let name = (payload["name"] as? String) ?? ""
        let arguments = toolArguments(payload)
        switch name {
        case "apply_patch":
            return "正在编辑 \(patchTarget(payload) )".trimmingCharacters(in: .whitespaces)
        case "shell":
            return shellStatus(arguments["command"] as? String)
        case "update_plan":
            return "正在更新计划"
        case "view_image":
            return "正在查看图片"
        case "read_file":
            return pathLabel(arguments["path"] as? String).map { "正在读取 \($0)" } ?? "正在读取文件"
        case "write_file":
            return pathLabel(arguments["path"] as? String).map { "正在写入 \($0)" } ?? "正在写入文件"
        case "js":
            return "正在执行脚本"
        default:
            return name.isEmpty ? "正在运行工具" : "正在运行 \(name)"
        }
    }

    private static func patchTarget(_ payload: [String: Any]) -> String {
        let input = (payload["input"] as? String)
            ?? ((payload["arguments"] as? String) ?? "")
        // *** Update/Add/Delete File: path → 文件名
        for line in input.split(separator: "\n") {
            for verb in ["Update File: ", "Add File: ", "Delete File: "] {
                if line.contains("*** \(verb)") {
                    let raw = line
                        .components(separatedBy: verb).last?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    let name = (raw as NSString).lastPathComponent
                    if !name.isEmpty { return shorten(name, limit: 24) }
                }
            }
        }
        return "文件"
    }

    private static func shellStatus(_ command: String?) -> String {
        guard let command, !command.isEmpty else { return "正在运行命令" }
        let lower = command.lowercased()
        if lower.contains("idf.py") {
            if lower.contains("flash") { return "正在烧录固件" }
            if lower.contains("build") { return "正在编译固件" }
        }
        if lower.contains("git status") { return "正在检查工程状态" }
        if lower.contains("git diff") { return "正在查看改动" }
        if let label = pathLabel(command) { return "正在运行 \(label)" }
        return "正在运行命令"
    }

    private static func toolArguments(_ payload: [String: Any]) -> [String: Any] {
        if let args = payload["arguments"] as? [String: Any] { return args }
        if let args = payload["input"] as? [String: Any] { return args }
        if let text = payload["arguments"] as? String,
           let data = text.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return args
        }
        return [:]
    }

    /// 命令/参数文本 → 文件名(路径的 lastPathComponent), 无则 nil。
    static func pathLabel(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let trimmed = text
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !trimmed.isEmpty else { return nil }
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// 工具输出 → 一行摘要(优先 Exit code 行, 截 120 字)。
    static func summarizeToolOutput(_ output: Any?) -> String {
        var text: String
        switch output {
        case let string as String: text = string
        case let list as [[String: Any]]:
            text = list.compactMap { item in
                (item["text"] ?? item["output"] ?? item["content"]) as? String
            }.joined(separator: "\n")
        case let dict as [String: Any]:
            text = (dict["output"] as? String) ?? (dict["text"] as? String) ?? "工具已返回结果"
        default:
            return "工具已返回结果"
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var head = lines.first else { return "工具已返回结果" }
        for line in lines where line.hasPrefix("Exit code:") || line.hasPrefix("Output:") {
            head = line
            break
        }
        return shorten(head, limit: 120)
    }

    static func shorten(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    // MARK: - 杂项

    /// 时间戳 → 本地 HH:MM。
    static func timeLabel(_ raw: [String: Any]) -> String {
        if let stamp = raw["timestamp"] as? String {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: stamp) {
                return formatTime(date)
            }
            parser.formatOptions = [.withInternetDateTime]
            if let date = parser.date(from: stamp) {
                return formatTime(date)
            }
        }
        return formatTime(Date())
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// FNV-1a(事件 id 去重键)。
    static func stableHash(_ object: [String: Any]) -> String {
        let text = String(describing: object)
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 1_677_7619
        }
        return String(format: "%08x", hash)
    }
}
