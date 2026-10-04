import CryptoKit
import Foundation

/// 每个仓库（工作目录）一份 Git 命令记录，供事后回溯与耗时排查。
/// 每行 Tab 分隔：开始时间 / 耗时 ms / 结果 / stdout 字节 / 命令 / 失败信息；`sort -t$'\t' -k2 -n` 找慢命令。
enum GitCommandLog {
    static let directory = ConfigStore.directory.appendingPathComponent("logs", isDirectory: true)
    private static let queue = DispatchQueue(label: "jj-git.command-log", qos: .utility)
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)
    private static let argumentLimit = 2000

    /// 只排队写入，不阻塞 Git 调用；写入失败直接忽略。
    static func record(at repository: String, arguments: [String], start: Date, milliseconds: Int,
                       result: Result<GitOutput, any Error>) {
        let config = AppConfig.current.commandLog
        guard config.enabled else { return }
        let outcome: String, bytes: Int, note: String
        switch result {
        case let .success(output):
            outcome = "exit=\(output.status)"
            bytes = output.data.count
            note = output.status == 0 ? "" : output.error
        case let .failure(error as GitFailure):
            outcome = error.timedOut ? "timeout" : "error"
            bytes = 0
            note = error.message
        case .failure(is CancellationError):
            outcome = "cancelled"
            bytes = 0
            note = ""
        case let .failure(error):
            outcome = "error"
            bytes = 0
            note = error.localizedDescription
        }
        let summary = note.split(whereSeparator: \.isNewline).first.map { escape(redact(String($0.prefix(300)))) } ?? ""
        let line = [start.formatted(timestamp), "\(milliseconds)", outcome, "\(bytes)", command(arguments), summary]
            .joined(separator: "\t") + "\n"
        let limit = config.maxFileMiB * 1024 * 1024
        queue.async { append(line, repository: repository, limit: limit) }
    }

    private static func append(_ line: String, repository: String, limit: Int) {
        let manager = FileManager.default
        let url = fileURL(for: repository)
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let rotating = size.map { $0 > limit } ?? false
        do {
            if rotating {
                // 仅保留上一份，总占用上限约为 2 倍 maxFileMiB。
                let previous = url.appendingPathExtension("1")
                try? manager.removeItem(at: previous)
                try manager.moveItem(at: url, to: previous)
            }
            if size == nil || rotating {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let header = "# \(repository)\n# start\tms\tresult\tstdout_bytes\tcommand\terror\n"
                try Data(header.utf8).write(to: url)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
        }
    }

    /// `<目录名>-<路径哈希>.log`：同名仓库互不覆盖，文件名仍可辨认。
    private static func fileURL(for repository: String) -> URL {
        let digest = SHA256.hash(data: Data(repository.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = URL(fileURLWithPath: repository).lastPathComponent
            .map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" }
        return directory.appendingPathComponent("\(String(name))-\(digest).log")
    }

    private static func command(_ arguments: [String]) -> String {
        var text = "git"
        for (index, argument) in arguments.enumerated() {
            if text.count > argumentLimit {
                return text + " …(+\(arguments.count - index) args)"
            }
            text += " " + quote(redact(argument))
        }
        return text
    }

    /// 远程 URL 可能内嵌凭据：`scheme://user:token@host` 只保留主机部分。
    private static func redact(_ argument: String) -> String {
        argument.replacingOccurrences(of: #"://[^/@\s]+@"#, with: "://***@", options: .regularExpression)
    }

    private static func quote(_ argument: String) -> String {
        let plain = !argument.isEmpty && argument.allSatisfy { !$0.isWhitespace && !"'\"\\$`".contains($0) }
        return plain ? argument : "'" + escape(argument.replacingOccurrences(of: "'", with: #"'\''"#)) + "'"
    }

    /// 保证一条命令只占一行、字段内不含 Tab。
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }
}
