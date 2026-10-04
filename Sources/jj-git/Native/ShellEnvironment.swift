import Foundation
import os

/// 从 Finder / Dock 启动的 App 不继承登录 shell 的 PATH；Git hooks 依赖的 node / bun 等工具需要它。
enum ShellEnvironment {
    private static let captured = OSAllocatedUnfairLock<String?>(initialState: nil)

    static var path: String? {
        captured.withLock { $0 }
    }

    /// 启动时调用一次；读取完成前 Git 使用默认 PATH。
    static func load() {
        DispatchQueue.global(qos: .utility).async {
            guard let value = capture() else { return }
            captured.withLock { $0 = value }
        }
    }

    private static func capture() -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jj-git-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        // 交互式登录 shell 才会加载 .zshrc 中的 fnm / mise 等配置；结果写文件，避免后台子进程占住管道。
        process.arguments = ["-ilc", "printf '%s' \"$PATH\" > \"$1\"", "jj-git", file.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // 交互式 shell 会忽略 SIGTERM，超时直接 SIGKILL。
        let processID = process.processIdentifier
        let timeout = DispatchWorkItem { kill(processID, SIGKILL) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0,
              let value = try? String(contentsOf: file, encoding: .utf8),
              value.hasPrefix("/") else { return nil }
        return value
    }
}
