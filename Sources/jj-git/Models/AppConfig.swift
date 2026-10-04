import Foundation
import os

/// `config.json` 的内容：缺失的键取默认值，越界数值收敛到可用范围。
struct AppConfig: Codable, Equatable, Sendable {
    struct Editor: Codable, Equatable, Sendable {
        /// 外部编辑器 .app 路径；为空或不存在时按 `bundleID` 查找。
        var path = ""
        var bundleID = "com.microsoft.VSCode"
    }

    struct Terminal: Codable, Equatable, Sendable {
        /// 按顺序使用第一个已安装的终端。
        var bundleIDs = ["com.googlecode.iterm2", "com.apple.Terminal"]
    }

    struct Git: Codable, Equatable, Sendable {
        /// 为空时自动查找 Homebrew / 系统 Git。
        var executable = ""
        var timeoutSeconds = 30
        /// 提交会运行 hooks，单独放宽。
        var commitTimeoutSeconds = 120
        var networkTimeoutSeconds = 180
        var outputLimitMiB = 16
    }

    struct Pull: Codable, Equatable, Sendable {
        var rebase = true
        var autostash = true
    }

    struct History: Codable, Equatable, Sendable {
        var initialCount = 2000
        var pageSize = 500
    }

    struct Diff: Codable, Equatable, Sendable {
        /// 下限 1：按行暂存生成的补丁依赖上下文定位。
        var contextLines = 3
    }

    struct Refresh: Codable, Equatable, Sendable {
        /// 前台兜底轮询间隔；文件变化本身由 FSEvents 实时触发。
        var pollSeconds = 5
    }

    var editor = Editor()
    var terminal = Terminal()
    var git = Git()
    var pull = Pull()
    var history = History()
    var diff = Diff()
    var refresh = Refresh()

    func normalized() -> AppConfig {
        var value = self
        value.editor.path = editor.path.trimmingCharacters(in: .whitespacesAndNewlines)
        value.editor.bundleID = editor.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        value.terminal.bundleIDs = terminal.bundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        value.git.executable = git.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        value.git.timeoutSeconds = git.timeoutSeconds.clamped(1...3600)
        value.git.commitTimeoutSeconds = git.commitTimeoutSeconds.clamped(1...3600)
        value.git.networkTimeoutSeconds = git.networkTimeoutSeconds.clamped(1...3600)
        value.git.outputLimitMiB = git.outputLimitMiB.clamped(1...512)
        value.history.initialCount = history.initialCount.clamped(50...100_000)
        value.history.pageSize = history.pageSize.clamped(50...100_000)
        value.diff.contextLines = diff.contextLines.clamped(1...20)
        value.refresh.pollSeconds = refresh.pollSeconds.clamped(1...600)
        return value
    }

    private static let shared = OSAllocatedUnfairLock(initialState: AppConfig())

    /// Git 进程在后台队列读取，主线程加载配置后写入。
    static var current: AppConfig {
        get { shared.withLock { $0 } }
        set { shared.withLock { $0 = newValue } }
    }
}

private extension Int {
    func clamped(_ range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
