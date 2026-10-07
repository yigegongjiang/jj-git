import Foundation

struct GitFailure: LocalizedError, Sendable {
    let message: String
    var timedOut = false
    var errorDescription: String? {
        message
    }
}

struct GitOutput: Sendable {
    let data: Data
    let error: String
    let status: Int32

    var text: String {
        String(bytes: data, encoding: .utf8) ?? "Git output is not UTF-8."
    }

    func checkedText() throws -> String {
        guard let value = String(bytes: data, encoding: .utf8) else {
            throw GitFailure(message: "Git 输出包含非 UTF-8 内容，无法安全处理。")
        }
        return value
    }
}

/// 收到 stderr 最新一行（`--progress` 进度 / hooks 输出）；在后台队列调用。
typealias GitProgressHandler = @Sendable (String) -> Void

/// 一次子进程调用：Git 命令与自定义操作共用超时 / 取消 / 输出上限 / 命令记录。
struct ProcessCommand: Sendable {
    let executable: String
    let arguments: [String]
    /// 命令记录中的形式：Git 省略固定的前缀参数。
    let logged: [String]
    /// 叠加在默认环境之上。
    var environment: [String: String] = [:]
    /// 超时 / 输出超限提示中的操作名与建议。
    var name = "Git 操作"
    var timeoutHint = "请检查网络或 Git hooks。"
    var limitHint = "请缩小所选文件或历史范围。"
}

/// 每次调用独立进程；不经过 shell，取消与超时会终止整个进程组。
enum GitProcess {
    private static let detected = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    /// 登录 shell PATH 之后追加，保证 Homebrew / 系统工具可用。
    static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static var searchPath: String {
        (ShellEnvironment.path ?? ProcessInfo.processInfo.environment["PATH"] ?? "") + ":" + fallbackPath
    }

    static func run(
        at directory: String, _ arguments: [String], input: Data? = nil,
        accepted: Set<Int32> = [0], timeout: TimeInterval? = nil, progress: GitProgressHandler? = nil
    ) async throws -> GitOutput {
        let config = AppConfig.current.git
        let executable = config.executable.isEmpty ? detected : config.executable
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw GitFailure(message: "config.jsonc git.executable 不可执行：\(executable)")
        }
        let command = ProcessCommand(executable: executable,
                                     arguments: ["--no-pager", "--literal-pathspecs", "-c", "color.ui=false",
                                                 "-c", "core.quotepath=false"] + arguments,
                                     logged: ["git"] + arguments)
        return try await execute(command, at: directory, input: input, accepted: accepted,
                                 timeout: timeout ?? TimeInterval(config.timeoutSeconds), progress: progress)
    }

    static func execute(
        _ command: ProcessCommand, at directory: String, input: Data? = nil,
        accepted: Set<Int32> = [0], timeout: TimeInterval, progress: GitProgressHandler? = nil
    ) async throws -> GitOutput {
        let execution = GitExecution(command: command,
                                     outputLimit: AppConfig.current.git.outputLimitMiB * 1024 * 1024,
                                     progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let start = Date()
                    let begin = DispatchTime.now().uptimeNanoseconds
                    let result = Result {
                        try execution.run(at: directory, input: input, timeout: timeout)
                    }
                    GitCommandLog.record(at: directory, command: command.logged, start: start,
                                         milliseconds: Int((DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000),
                                         result: result)
                    do {
                        let output = try result.get()
                        guard accepted.contains(output.status) else {
                            let detail = (output.error.isEmpty ? output.text : output.error)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            throw GitFailure(message: detail.isEmpty ? "退出码 \(output.status)" : detail)
                        }
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }

    /// 启动后不等待：输入输出接空设备（无人读取的管道写满会阻塞子进程）；退出后由 Foundation 回收。
    static func launch(_ command: ProcessCommand, at directory: String) throws {
        let process = makeProcess(command, at: directory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let start = Date()
        let result = Result { try process.run() }
        GitCommandLog.record(at: directory, command: command.logged, start: start, milliseconds: 0,
                             result: result.map { GitOutput(data: Data(), error: "", status: 0) })
        try result.get()
    }

    fileprivate static func makeProcess(_ command: ProcessCommand, at directory: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = searchPath
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_EDITOR"] = "/usr/bin/true"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment.merge(command.environment) { $1 }
        process.environment = environment
        return process
    }
}

private final class GitExecution: @unchecked Sendable {
    private let command: ProcessCommand
    private let outputLimit: Int
    private let progress: GitProgressHandler?
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var failure: GitFailure?
    private var reported: String?

    init(command: ProcessCommand, outputLimit: Int, progress: GitProgressHandler?) {
        self.command = command
        self.outputLimit = outputLimit
        self.progress = progress
    }

    func cancel(failure reason: GitFailure? = nil) {
        lock.lock()
        cancelled = true
        failure = failure ?? reason
        if let process, process.isRunning {
            // Git 的 hooks / SSH 子进程可能持有句柄；一起终止，避免后台遗留。
            let processID = process.processIdentifier
            if getpgid(processID) == processID {
                kill(-processID, SIGKILL)
            } else {
                kill(processID, SIGKILL)
            }
        }
        lock.unlock()
    }

    func run(at directory: String, input: Data?, timeout: TimeInterval) throws -> GitOutput {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("jj-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout")
        let errorURL = temporary.appendingPathComponent("stderr")
        let inputURL = temporary.appendingPathComponent("stdin")
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        try (input ?? Data()).write(to: inputURL)
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        let stdin = try FileHandle(forReadingFrom: inputURL)
        defer {
            try? stdout.close()
            try? stderr.close()
            try? stdin.close()
        }

        let child = GitProcess.makeProcess(command, at: directory)
        child.standardOutput = stdout
        child.standardError = stderr
        child.standardInput = stdin
        // outputs[1] = stderr：进度与 hooks 输出所在。
        try execute(child, timeout: timeout, outputs: [outputURL, errorURL])
        let errors = try readBounded(errorURL)
        return try GitOutput(data: readBounded(outputURL),
                             error: String(bytes: errors, encoding: .utf8).map(Self.collapse)
                                 ?? "Git error output is not UTF-8.",
                             status: child.terminationStatus)
    }

    /// `--progress` 用 `\r` 原地刷新同一行；每行只保留最终状态，供提示 / 错误 / 日志使用。
    private static func collapse(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        return text.components(separatedBy: "\n")
            .map { $0.components(separatedBy: "\r").last { !$0.isEmpty } ?? "" }
            .joined(separator: "\n")
    }

    /// 仅在计时器队列调用（同一 timer 串行执行）。
    private func reportProgress(_ url: URL) {
        guard let progress, let line = latestLine(url), line != reported else { return }
        reported = line
        progress(line)
    }

    /// 只读 stderr 末尾 4 KiB，取最后一个非空片段；不随输出总量增长。
    private func latestLine(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let segments = data.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D })
        // 截断点可能落在多字节字符中间，丢弃无法解码的片段。
        return segments.reversed().lazy.compactMap { String(bytes: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    private func execute(_ command: Process, timeout: TimeInterval, outputs: [URL]) throws {
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        do {
            try command.run()
            process = command
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let deadline = DispatchTime.now() + timeout
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        let limit = outputLimit
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            reportProgress(outputs[1])
            if DispatchTime.now() >= deadline {
                cancel(failure: timeoutFailure(timeout))
            } else if outputs.contains(where: { url in
                let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                return (size ?? 0) > limit
            }) {
                cancel(failure: limitFailure())
            }
        }
        timer.resume()
        command.waitUntilExit()
        timer.cancel()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        let reason = failure
        lock.unlock()
        if let reason {
            throw reason
        }
        if wasCancelled {
            throw CancellationError()
        }
    }

    private func timeoutFailure(_ timeout: TimeInterval) -> GitFailure {
        GitFailure(message: "\(command.name)超时（\(Int(timeout)) 秒）。\(command.timeoutHint)", timedOut: true)
    }

    private func limitFailure() -> GitFailure {
        GitFailure(message: "\(command.name)输出超过 \(outputLimit / 1024 / 1024) MiB，\(command.limitHint)")
    }

    private func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: outputLimit + 1) ?? Data()
        guard data.count <= outputLimit else {
            throw limitFailure()
        }
        return data
    }
}
