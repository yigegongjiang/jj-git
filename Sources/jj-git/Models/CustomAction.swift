import Foundation

/// `config.jsonc` `customActions` 的一项：在当前仓库目录执行的外部命令，参数逐项传递、不经 shell。
struct CustomAction: Codable, Equatable, Sendable {
    var name = ""
    /// 绝对路径（支持 `~/`），或在登录 shell PATH 中查找的命令名。
    var executable = ""
    var arguments: [String] = []
    /// true：占用操作状态栏直到退出，显示输出 / 错误，可取消；false：启动后不等待、不收集输出。
    var waitForExit = true
    var timeoutSeconds = 600

    /// 参数中的 `${NAME}` 与环境变量 `JJ_GIT_NAME` 的取值来源。
    static let variables = ["REPO", "BRANCH", "SHA", "REMOTE"]

    /// 仅替换已知变量且只替换一遍：取值中的 `${...}` 原样保留；其他 `${...}` 留给被调用的程序。
    func expandedArguments(_ values: [String: String]) -> [String] {
        arguments.map { argument in
            argument.replacing(/\$\{([A-Z]+)\}/) { match in
                values[String(match.1)] ?? String(match.0)
            }
        }
    }

    /// 带 `/` 的按路径使用，否则依次在 PATH 各目录查找。
    func resolvedExecutable(searchPath: String) throws -> String {
        let configured = (executable as NSString).expandingTildeInPath
        if configured.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: configured) else {
                throw GitFailure(message: "自定义操作「\(name)」executable 不可执行：\(configured)")
            }
            return configured
        }
        let found = searchPath.split(separator: ":").lazy
            .map { String($0) + "/" + configured }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let found else {
            throw GitFailure(message: "自定义操作「\(name)」在 PATH 中找不到 executable：\(configured)")
        }
        return found
    }

    func normalized() -> CustomAction {
        var value = self
        value.executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.name.isEmpty {
            value.name = (value.executable as NSString).lastPathComponent
        }
        value.timeoutSeconds = Swift.min(Swift.max(timeoutSeconds, 1), 86400)
        return value
    }
}

extension CustomAction {
    private enum CodingKeys: String, CodingKey {
        case name, executable, arguments, waitForExit, timeoutSeconds
    }

    /// 数组元素不经默认值合并：缺失键 / null 在此取默认值。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CustomAction()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        executable = try container.decodeIfPresent(String.self, forKey: .executable) ?? defaults.executable
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? defaults.arguments
        waitForExit = try container.decodeIfPresent(Bool.self, forKey: .waitForExit) ?? defaults.waitForExit
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
    }
}
