import Foundation

/// ~/.codex/sessions 多会话 tail 轮询器。
///
/// 职责对齐 P4 参考的宿主职责(概念独立实现): 发现最近会话 → 跟踪文件尾部
/// 增量 → jsonl 行 → CodexTailEvent。文件轮询(0.5s)而非 FSEvents — 会话
/// 目录树深、文件轮询在 6 文件规模下更稳(mtime 单一事实, 无事件合并坑)。
///
/// 轮换/截断处理: mtime 或大小回退 → 从头重扫但只保留去重后新事件
/// (event id = 时间戳+行哈希, 稳定)。
final class CodexTailWatcher {
    /// 每个解析出的关注事件(主线程回调)。
    var onEvent: ((CodexTailEvent) -> Void)?
    /// 会话列表变化(新会话文件出现)。
    var onSessionsChanged: (([CodexSessionRef]) -> Void)?

    let sessionsRoot: URL
    private let queue = DispatchQueue(label: "codexpet.tail", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let stateStore: CodexStateStore

    /// 每会话跟踪状态。
    private struct Tracker {
        var ref: CodexSessionRef
        var offset: Int64
    }
    private var trackers: [Tracker] = []
    private var lastScanAt = Date.distantPast
    private var seenEventIDs: Set<String> = []
    private var seenEventOrder: [String] = []

    init(sessionsRoot: URL? = nil, stateStore: CodexStateStore = CodexStateStore()) {
        self.sessionsRoot = sessionsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions")
        self.stateStore = stateStore
    }

    func start() {
        guard timer == nil else { return }
        scanSessions(force: true)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        scanSessions(force: false)
        for index in trackers.indices {
            readIncrement(&trackers[index])
        }
    }

    // MARK: - 会话发现

    private func scanSessions(force: Bool) {
        guard force || Date().timeIntervalSince(lastScanAt) > 3 else { return }
        lastScanAt = Date()
        let found = CodexSessionParser.recentSessions(root: sessionsRoot)
        let known = Set(trackers.map(\.ref.path))
        let fresh = found.filter { !known.contains($0.path) }
        guard !fresh.isEmpty || force else { return }
        for ref in fresh {
            // 新会话从当前文件尾开始 — 不回放历史(用户要"现在", 不要刷屏)。
            let size = ((try? FileManager.default.attributesOfItem(atPath: ref.path.path))?[.size] as? Int64) ?? 0
            trackers.append(Tracker(ref: ref, offset: size))
        }
        if !found.isEmpty { onSessionsChanged?(found) }
    }

    // MARK: - 增量读取

    private func readIncrement(_ tracker: inout Tracker) {
        let path = tracker.ref.path.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else {
            return
        }
        if size < tracker.offset {
            // 截断/轮换: 重置到 0 重扫(事件 id 去重兜底)。
            tracker.offset = 0
        }
        guard size > tracker.offset else { return }
        guard let handle = try? FileHandle(forReadingFrom: tracker.ref.path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(tracker.offset))
        guard let chunk = try? handle.read(upToCount: Int(size - tracker.offset)) else { return }
        tracker.offset = size

        var buffer = pendingBuffers[tracker.ref.path] ?? Data()
        buffer.append(chunk)
        pendingBuffers[tracker.ref.path] = buffer
        flushLines(for: tracker.ref)
    }

    /// 半行缓冲: 文件尾正在写入的行留在缓冲等下一轮。
    private var pendingBuffers: [URL: Data] = [:]

    private func flushLines(for ref: CodexSessionRef) {
        guard var buffer = pendingBuffers[ref.path] else { return }
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            if !lineData.isEmpty,
               let text = String(data: Data(lineData), encoding: .utf8) {
                lines.append(text)
            }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        pendingBuffers[ref.path] = buffer
        for line in lines {
            guard let event = CodexSessionParser.parse(line: line, project: ref.project) else { continue }
            // 文件截断后会从头重扫；用稳定事件 id 做有界去重，避免消息中心
            // 和 MK20 气泡重复播放同一条历史事件。
            guard seenEventIDs.insert(event.id).inserted else { continue }
            seenEventOrder.append(event.id)
            if seenEventOrder.count > 5_000 {
                let expiredCount = seenEventOrder.count - 4_000
                for expired in seenEventOrder.prefix(expiredCount) {
                    seenEventIDs.remove(expired)
                }
                seenEventOrder.removeFirst(expiredCount)
            }
            // token_count 补累计值(state_5.sqlite 优先, 事件值兜底)。
            var enriched = event
            if event.isTokenCount {
                let cumulative = stateStore.cumulativeTokens()
                if let cumulative, cumulative >= (event.totalTokens ?? 0) {
                    enriched.totalTokens = cumulative
                }
            }
            onEvent?(enriched)
        }
    }
}
