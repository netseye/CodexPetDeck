import Foundation
import SQLite3

/// Codex 本机状态只读访问: state_5.sqlite(threads 累计 token)。
///
/// ⚠ 只读打开(SQLITE_OPEN_READONLY); Codex 进程持有写锁时并发读安全。
/// 130MB 的库单行 SUM 在本机实测毫秒级, 10s 缓存足够。
final class CodexStateStore {
    let databaseURL: URL
    private var cachedTotal: (at: Date, value: Int)?
    private let cacheInterval: TimeInterval = 10

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/state_5.sqlite")
    }

    /// threads.tokens_used 累计(nil = 库不存在/不可读)。
    func cumulativeTokens() -> Int? {
        if let cache = cachedTotal, Date().timeIntervalSince(cache.at) < cacheInterval {
            return cache.value
        }
        guard let value = readTotal() else { return cachedTotal?.value }
        cachedTotal = (Date(), value)
        return value
    }

    private func readTotal() -> Int? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "SELECT COALESCE(SUM(tokens_used), 0) FROM threads", -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        // SUM 可能溢出 Int32 — 用 Int64 读。
        return Int(sqlite3_column_int64(statement, 0))
    }
}
