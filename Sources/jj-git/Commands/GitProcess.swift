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

/// 每次调用独立进程；不经过 shell，取消与超时会终止整个进程组。
enum GitProcess {
    private static let detected = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    static func run(
        at directory: String, _ arguments: [String], input: Data? = nil,
        accepted: Set<Int32> = [0], timeout: TimeInterval? = nil
    ) async throws -> GitOutput {
        let config = AppConfig.current.git
        let executable = config.executable.isEmpty ? detected : config.executable
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw GitFailure(message: "config.json git.executable 不可执行：\(executable)")
        }
        let timeout = timeout ?? TimeInterval(config.timeoutSeconds)
        let execution = GitExecution(executable: executable, outputLimit: config.outputLimitMiB * 1024 * 1024)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let output = try execution.run(
                            at: directory, arguments: arguments, input: input, timeout: timeout
                        )
                        guard accepted.contains(output.status) else {
                            let detail = output.error.isEmpty ? output.text : output.error
                            throw GitFailure(message: detail.trimmingCharacters(in: .whitespacesAndNewlines))
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
}

private final class GitExecution: @unchecked Sendable {
    private let executable: String
    private let outputLimit: Int
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var failure: GitFailure?

    init(executable: String, outputLimit: Int) {
        self.executable = executable
        self.outputLimit = outputLimit
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

    func run(at directory: String, arguments: [String], input: Data?, timeout: TimeInterval) throws -> GitOutput {
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

        let command = makeCommand(at: directory, arguments: arguments)
        command.standardOutput = stdout
        command.standardError = stderr
        command.standardInput = stdin
        try execute(command, timeout: timeout, outputs: [outputURL, errorURL])
        let errors = try readBounded(errorURL)
        return try GitOutput(data: readBounded(outputURL),
                             error: String(bytes: errors, encoding: .utf8) ?? "Git error output is not UTF-8.",
                             status: command.terminationStatus)
    }

    private func makeCommand(at directory: String, arguments: [String]) -> Process {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.currentDirectoryURL = URL(fileURLWithPath: directory)
        command.arguments = ["--no-pager", "--literal-pathspecs", "-c", "color.ui=false",
                             "-c", "core.quotepath=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (ShellEnvironment.path ?? environment["PATH"] ?? "") + ":" + fallback
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_EDITOR"] = "/usr/bin/true"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        command.environment = environment

        return command
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
            if DispatchTime.now() >= deadline {
                self?.cancel(failure: GitFailure(message: "Git 操作超时（\(Int(timeout)) 秒）。请检查网络或 Git hooks。",
                                                 timedOut: true))
            } else if outputs.contains(where: { url in
                let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                return (size ?? 0) > limit
            }) {
                self?.cancel(failure: GitFailure(message: "Git 输出超过 \(limit / 1024 / 1024) MiB，请缩小所选文件或历史范围。"))
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

    private func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: outputLimit + 1) ?? Data()
        guard data.count <= outputLimit else {
            throw GitFailure(message: "Git 输出超过 \(outputLimit / 1024 / 1024) MiB，请缩小所选文件或历史范围。")
        }
        return data
    }
}
