import Foundation

/// `~/.config/jj-git` 下的 JSON 文件；Debug 构建使用独立目录，调试不影响日常数据。
enum ConfigStore {
    #if DEBUG
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/jj-git-debug", isDirectory: true)
    #else
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/jj-git", isDirectory: true)
    #endif
    /// 设置：外部修改即时生效。
    static let configURL = directory.appendingPathComponent("config.json")
    /// 仓库列表 / 分组 / 标签：随界面操作写入，外部修改同样即时生效。
    static let stateURL = directory.appendingPathComponent("state.json")
    /// 全部可用键的默认值，每次启动刷新，仅供查阅。
    static let defaultsURL = directory.appendingPathComponent("config.default.json")

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

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
    static func decode<T: Codable>(_ data: Data, defaults: T) throws -> T {
        let override: Any
        do {
            override = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GitFailure(message: "不是合法的 JSON。")
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
