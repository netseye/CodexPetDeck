import Foundation

/// 布局 JSON 规范化输出(真机确认规则, §7):
/// 4 空格缩进 / Unix \n / 对象键每层字母序 / 所有数值序列化为字符串。
/// 这些不是审美 — 官方 ScreenKeyWindows 对格式敏感(§10 Item #10)。
enum ThemeJSONWriter {
    static func write(currentPageID: String, layoutVersion: String, pages: [PageBuilder.BuiltPage]) -> String {
        var root: JSONValue = .object([
            "main": .object([
                "currentPage": .string(currentPageID),
                "version": .string(layoutVersion),
            ]),
            "pages": .array(pages.map(pageJSON)),
        ])
        normalize(&root)
        return render(root)
    }

    private static func pageJSON(_ page: PageBuilder.BuiltPage) -> JSONValue {
        var object: [String: JSONValue] = [
            "canvas": .object(page.canvas.mapValues { .string($0) }),
            "encoder": .raw(page.encoderJSON),
            "items": .array(page.items.map { .object($0.mapValues { .string($0) }) }),
            "pageName": .string(page.pageID),
        ]
        if let parentPageID = page.parentPageID {
            object["parentPageName"] = .string(parentPageID)
        }
        return .object(object)
    }

    // MARK: - 轻量 JSON 值树(避免 Foundation JSONSerialization 的无序字典)

    enum JSONValue {
        case string(String)
        case object([String: JSONValue])
        case array([JSONValue])
        /// 预序列化片段(encoder 数组等, 已符合规范化规则)。
        case raw(String)
    }

    /// 递归键字母序(ordinal, 与官方一致)。
    private static func normalize(_ value: inout JSONValue) {
        switch value {
        case .object(let members):
            var sorted: [String: JSONValue] = [:]
            for (key, var member) in members {
                normalize(&member)
                sorted[key] = member
            }
            value = .object(sorted)
        case .array(let items):
            var normalized = items
            for index in items.indices {
                normalize(&normalized[index])
            }
            value = .array(normalized)
        case .string, .raw:
            break
        }
    }

    /// 渲染为规范化文本: 4 空格缩进、\n、最小转义(\" 与 \\,不转义非 ASCII)。
    private static func render(_ value: JSONValue) -> String {
        var out = ""
        renderValue(value, indent: "", into: &out)
        return out
    }

    private static func renderValue(_ value: JSONValue, indent: String, into out: inout String) {
        switch value {
        case .string(let text):
            out += quote(text)
        case .raw(let text):
            out += text
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += indent + "    "
                renderValue(item, indent: indent + "    ", into: &out)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += indent + "]"
        case .object(let members):
            if members.isEmpty {
                out += "{}"
                return
            }
            out += "{\n"
            let ordered = members.sorted { $0.key < $1.key }
            for (index, entry) in ordered.enumerated() {
                out += indent + "    " + quote(entry.key) + ": "
                renderValue(entry.value, indent: indent + "    ", into: &out)
                out += index == ordered.count - 1 ? "\n" : ",\n"
            }
            out += indent + "}"
        }
    }

    /// 最小转义: 仅 \" 与 \\(官方文件不含 \uXXXX 形式, 中文原样 UTF-8)。
    private static func quote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
