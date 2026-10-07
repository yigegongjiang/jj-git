import Foundation

/// `~/.config/jj-git` 下的配置与状态文件；Debug 构建使用产物旁的独立目录，调试不影响日常数据。
enum ConfigStore {
    #if DEBUG
    /// 放在 .app 同级：每份构建 (每个 worktree) 独立，多实例并行调试互不覆盖，随 build 目录删除。
    static let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("debug-config", isDirectory: true)
    #else
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/jj-git", isDirectory: true)
    #endif
    /// 设置：启动时读取。
    static let configURL = directory.appendingPathComponent("config.jsonc")
    /// 仓库列表 / 分组 / 标签：启动时读取，随界面操作写入。
    static let stateURL = directory.appendingPathComponent("state.json")
    /// 全部可用键的默认值，每次启动刷新，仅供查阅。
    static let defaultsURL = directory.appendingPathComponent("config.default.jsonc")

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    /// 默认模板与新建配置均带逐键说明；数值取自模型。同名键按 `分组.键` 区分说明。
    static func encodeConfig(_ config: AppConfig) throws -> Data {
        let text = try utf8(encode(config))
        var section = ""
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let parts = line.split(separator: "\"", maxSplits: 2)
            guard parts.count == 3 else { return line }
            let indent = String(line.prefix(while: { $0 == " " }))
            if indent.count == 2 {
                section = String(parts[1])
            }
            guard let note = configNotes[section + "." + parts[1]] ?? configNotes[String(parts[1])] else { return line }
            return note.components(separatedBy: "\n").map { "\(indent)// \($0)\n" }.joined() + line
        }
        return Data(("// 修改后重启生效；缺失键 / null 取默认值，越界数值收敛。\n" + lines.joined(separator: "\n")).utf8)
    }

    static func readConfig(_ data: Data?) throws -> AppConfig {
        try data.map { try decode($0, defaults: AppConfig(), comments: true) } ?? AppConfig()
    }

    /// 界面操作只改变化的值，保留用户注释、未知键与格式。
    static func saveConfig(_ config: AppConfig, original: Data?) throws {
        guard let original else {
            try write(encodeConfig(config), to: configURL)
            return
        }
        let old = try decode(original, defaults: AppConfig(), comments: true)
        let before = try JSONSerialization.jsonObject(with: encode(old)) as? [String: Any] ?? [:]
        let after = try JSONSerialization.jsonObject(with: encode(config)) as? [String: Any] ?? [:]
        var text = try utf8(original)
        for section in after.keys.sorted() {
            guard let current = after[section] else { continue }
            // 数组（customActions）整体比较、整体替换；分组逐键替换。
            guard let values = current as? [String: Any] else {
                if !same(before[section], current) {
                    text = try replacing(current, path: [section], in: text)
                }
                continue
            }
            let previous = before[section] as? [String: Any] ?? [:]
            for key in values.keys.sorted() {
                guard let value = values[key], !same(previous[key], value) else { continue }
                text = try replacing(value, path: [section, key], in: text)
            }
        }
        guard try decode(Data(text.utf8), defaults: AppConfig(), comments: true) == config else {
            throw GitFailure(message: "配置写入校验失败，原文件已保留。")
        }
        try write(Data(text.utf8), to: configURL)
    }

    private static func same(_ old: Any?, _ new: Any) -> Bool {
        NSDictionary(dictionary: ["value": old ?? NSNull()]).isEqual(to: ["value": new])
    }

    static func utf8(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitFailure(message: "配置必须使用 UTF-8 编码。")
        }
        return text
    }

    private static func replacing(_ value: Any, path: [String], in text: String) throws -> String {
        var editor = try ConfigTextEditor(text)
        return try editor.replacing(value, path: path[...])
    }

    private static let configNotes: [String: String] = [
        "appearance": "字体与差异行距",
        "fontFamily": "界面字体族；空值 / 未安装使用系统字体。",
        "monospaceFontFamily": "代码等宽字体族；空值 / 未安装使用系统等宽字体。",
        "fontSize": "界面字号（pt），9–20。",
        "editorFontSize": "差异 / 提交信息字号（pt），9–20。",
        "diffLineSpacing": "差异行额外间距（pt），0–20；0 为字体自然行高。",
        "editor": "外部编辑器",
        "path": "编辑器 .app 绝对路径；为空 / 不存在时按 bundleID 查找。",
        "bundleID": "编辑器 App 的 bundle identifier。",
        "fileManager": "文件管理器",
        "fileManager.bundleID": "「在文件夹中显示」App 的 bundle identifier；未安装 / 空值使用 Finder。",
        "terminal": "外部终端",
        "bundleIDs": "终端 bundle identifier，依次使用第一个已安装 App。",
        "git": "Git 执行限制",
        "executable": "Git 可执行文件绝对路径；空值自动查找 Homebrew / 系统 Git。",
        "timeoutSeconds": "普通 Git 命令超时（秒），1–3600。",
        "commitTimeoutSeconds": "提交超时（秒，含 hooks），1–3600。",
        "networkTimeoutSeconds": "网络命令超时（秒），1–3600。",
        "outputLimitMiB": "单次命令输出上限（MiB），1–512。",
        "commit": "提交信息",
        "defaultMessage": "提交信息输入框默认内容，提交后恢复；空值不预填。",
        "pull": "Pull 行为",
        "rebase": "true 使用 rebase；false 使用 merge。",
        "autostash": "Pull 时临时保存未提交修改，结束后恢复。",
        "history": "提交历史与显示列",
        "initialCount": "首次加载提交数，50–100000。",
        "pageSize": "每次追加加载提交数，50–100000。",
        "showReferences": "显示分支 / 标签列。",
        "showAuthor": "显示作者列。",
        "showTime": "显示提交时间列（本地时区）。",
        "compactTime": "true 精简时间 yyMMdd.HHmm；false 完整时间 yyyy-MM-dd HH:mm。",
        "showHash": "显示 SHA 列。",
        "diff": "差异预览",
        "contextLines": "差异上下文行数，1–20；按行暂存依赖上下文。",
        "previewTimeoutMilliseconds": "全部文件差异预处理预算（ms），100–30000；超时回退首文件。",
        "refresh": "状态刷新",
        "pollSeconds": "App 前台兜底轮询间隔（秒），1–600；文件变化另由 FSEvents 触发。",
        "autoFetchSeconds": "自动 Fetch 默认远程的间隔（秒），0 关闭，1–3600；仅当前标签，App 位于后台时同样执行。",
        "tabs": "标签与最近仓库",
        "idleUnloadSeconds": "未激活标签 session 保留时间（秒），1–86400；超时释放，点击重新加载。",
        "recentCount": "⌘P 最近仓库条数，1–100。",
        "commandLog": "Git 命令记录",
        "enabled": "记录每仓库 Git 命令、结果与耗时至 logs/。",
        "maxFileMiB": "单仓库日志上限（MiB），1–100；超出轮转，仅保留一份 .log.1。",
        "customActions": """
        自定义操作：工具栏 ▷ 菜单按顺序列出，在当前仓库（工作树）目录执行；参数逐项传递，不经 shell。
          name：菜单显示名；空值使用 executable 文件名。
          executable：绝对路径（支持 ~/），或在登录 shell PATH 中查找的命令名。
          arguments：参数数组；${REPO} ${BRANCH} ${SHA} ${REMOTE} 替换为仓库路径 / 当前分支（分离为 HEAD）/ HEAD SHA / 默认远程。
            同名环境变量 JJ_GIT_REPO / JJ_GIT_BRANCH / JJ_GIT_SHA / JJ_GIT_REMOTE；
            经 /bin/zsh -c 执行脚本时用 "$JJ_GIT_BRANCH" 引用，避免分支名被 shell 解释。
          waitForExit：默认 true，状态栏显示进度并可取消，结束后显示输出 / 错误；false 启动后不等待。
          timeoutSeconds：waitForExit 为 true 时的超时（秒），默认 600，1–86400。
        示例：
          "customActions": [
            { "name": "difftool（已暂存）", "executable": "git", "arguments": ["difftool", "-y", "--cached"] },
            { "name": "复制分支名", "executable": "/bin/zsh",
              "arguments": ["-c", "printf %s \\\"$JJ_GIT_BRANCH\\\" | pbcopy"] }
          ]
        """
    ]

    /// 文件不存在返回 nil。
    static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// 以默认值为底合并文件内容：缺失键或 null 取默认值，其余按类型解码。
    static func decode<T: Codable>(_ data: Data, defaults: T, comments: Bool = false) throws -> T {
        let override: Any
        do {
            override = try JSONSerialization.jsonObject(with: comments ? jsonData(data) : data)
        } catch {
            throw GitFailure(message: comments ? "不是合法的 JSONC。" : "不是合法的 JSON。")
        }
        guard override is [String: Any] else { throw GitFailure(message: "顶层必须是 JSON 对象。") }
        let base = try JSONSerialization.jsonObject(with: encode(defaults))
        let merged = try JSONSerialization.data(withJSONObject: merge(base, override))
        do {
            return try JSONDecoder().decode(T.self, from: merged)
        } catch let error as DecodingError {
            throw GitFailure(message: describe(error))
        }
    }

    /// 仅扩展注释与尾逗号；字符串原样保留，其余遵循 JSON 语法。
    private static func jsonData(_ data: Data) throws -> Data {
        let text = try utf8(data)
        let pattern = #"(?s)"(?:\\.|[^"\\])*"|//[^\r\n\u2028\u2029]*|/\*.*?\*/"#
        let expression = try NSRegularExpression(pattern: pattern)
        let result = NSMutableString(string: text)
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: result.length))
        for match in matches.reversed() {
            let value = result.substring(with: match.range)
            guard !value.hasPrefix("\"") else { continue }
            let whitespace = value.map { $0 == "\n" || $0 == "\r" ? String($0) : " " }.joined()
            result.replaceCharacters(in: match.range, with: whitespace)
        }
        return Data(String(result).utf8)
    }

    /// 指出出错的键，便于直接定位修改。
    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case let .typeMismatch(_, value), let .valueNotFound(_, value), let .keyNotFound(_, value),
             let .dataCorrupted(value):
            context = value
        @unknown default:
            return error.localizedDescription
        }
        let key = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return "\(key)：\(context.debugDescription)"
    }

    private static func merge(_ base: Any, _ override: Any) -> Any {
        if override is NSNull {
            return base
        }
        guard var result = base as? [String: Any], let values = override as? [String: Any] else { return override }
        for (key, value) in values {
            result[key] = result[key].map { merge($0, value) } ?? value
        }
        return result
    }
}

/// 已经原生解析验证的 JSONC：分词定位成员，只替换值或插入缺失键。
private struct ConfigTextEditor {
    let source: NSString
    let tokens: [NSTextCheckingResult]
    var cursor = 0

    init(_ text: String) throws {
        let source = text as NSString
        self.source = source
        // 字符串内的注释标记与转义引号不参与结构匹配。
        let pattern = #"(?s)//[^\r\n\u2028\u2029]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|"#
            + #"[^\s{}\[\],:]+|[{}\[\],:]"#
        tokens = try NSRegularExpression(pattern: pattern)
            .matches(in: text, range: NSRange(location: 0, length: source.length))
            .filter { !source.substring(with: $0.range).hasPrefix("//") &&
                !source.substring(with: $0.range).hasPrefix("/*")
            }
    }

    private func token(_ index: Int) -> String {
        guard tokens.indices.contains(index) else { return "" }
        return source.substring(with: tokens[index].range)
    }

    private mutating func valueRange() throws -> NSRange {
        guard tokens.indices.contains(cursor) else { throw GitFailure(message: "配置成员定位失败。") }
        let start = cursor
        if ["{", "["].contains(token(cursor)) {
            var depth = 0
            repeat {
                guard tokens.indices.contains(cursor) else { throw GitFailure(message: "配置成员定位失败。") }
                let part = token(cursor)
                if ["{", "["].contains(part) {
                    depth += 1
                }
                if ["}", "]"].contains(part) {
                    depth -= 1
                }
                cursor += 1
            } while depth > 0
        } else {
            cursor += 1
        }
        return NSRange(location: tokens[start].range.location,
                       length: NSMaxRange(tokens[cursor - 1].range) - tokens[start].range.location)
    }

    mutating func replacing(_ value: Any, path: ArraySlice<String>) throws -> String {
        guard token(cursor) == "{", let key = path.first else {
            // null 与默认值合并后也是有效对象，修改时替换整个值。
            var nested = value
            for name in path.reversed() { nested = [name: nested] }
            return try source.replacingCharacters(in: valueRange(), with: serialized(nested))
        }
        cursor += 1
        while token(cursor) != "}" {
            guard tokens.indices.contains(cursor) else { throw GitFailure(message: "配置成员定位失败。") }
            let rawKey = token(cursor)
            let name: String
            let decoded = try JSONSerialization.jsonObject(with: Data(rawKey.utf8), options: [.fragmentsAllowed])
            name = decoded as? String ?? rawKey
            cursor += 2 // 键 + 冒号
            if name == key {
                if path.count > 1 {
                    return try replacing(value, path: path.dropFirst())
                }
                return try source.replacingCharacters(in: valueRange(), with: serialized(value))
            }
            _ = try valueRange()
            if token(cursor) == "," {
                cursor += 1
            }
        }
        var addition = value
        for name in path.dropFirst().reversed() { addition = [name: addition] }
        let entry = try serialized([key: addition]).dropFirst().dropLast()
        let comma = ["{", ","].contains(token(cursor - 1)) ? "" : ","
        return source.replacingCharacters(in: NSRange(location: tokens[cursor].range.location, length: 0),
                                          with: "\(comma)\n\(entry)\n")
    }

    private func serialized(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value,
                                              options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return try ConfigStore.utf8(data)
    }
}
