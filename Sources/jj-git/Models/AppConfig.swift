import Foundation
import os

/// `config.jsonc` 的内容：缺失的键取默认值，越界数值收敛到可用范围。
struct AppConfig: Codable, Equatable, Sendable {
    struct Editor: Codable, Equatable, Sendable {
        /// 外部编辑器 .app 路径；为空或不存在时按 `bundleID` 查找。
        var path = ""
        var bundleID = "com.microsoft.VSCode"
    }

    struct FileBrowser: Codable, Equatable, Sendable {
        /// 「在文件夹中显示」使用的 App；未安装 / 为空时使用 Finder。
        var bundleID = "com.apple.finder"
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

    struct Commit: Codable, Equatable, Sendable {
        /// 提交信息输入框的初始内容，提交后恢复；为空不预填。
        var defaultMessage = ""
    }

    struct Pull: Codable, Equatable, Sendable {
        var rebase = true
        var autostash = true
    }

    struct History: Codable, Equatable, Sendable {
        var initialCount = 2000
        var pageSize = 500
        var showReferences = true
        var showAuthor = true
        var showTime = true
        var compactTime = false
        var showHash = true
    }

    struct Diff: Codable, Equatable, Sendable {
        /// 下限 1：按行暂存生成的补丁依赖上下文定位。
        var contextLines = 3
        /// 全文件差异读取与预处理的总预算（ms）。
        var previewTimeoutMilliseconds = 1000
    }

    struct Refresh: Codable, Equatable, Sendable {
        /// 前台兜底轮询间隔；文件变化本身由 FSEvents 实时触发。
        var pollSeconds = 5
        /// 当前标签定时 Fetch 默认远程的间隔（含 App 位于后台）；0 关闭。
        var autoFetchSeconds = 5
    }

    struct Tabs: Codable, Equatable, Sendable {
        /// 未激活标签的 session 保留时间；超时保留标签位置，点击重新加载。
        var idleUnloadSeconds = 180
        /// ⌘P 最近仓库列表显示条数。
        var recentCount = 15
    }

    struct Appearance: Codable, Equatable, Sendable {
        /// 字体族名称（如 "FiraCode Nerd Font Mono"）；为空或未安装时使用系统字体。
        var fontFamily = ""
        var monospaceFontFamily = ""
        /// 界面正文字号，标题 / 次要文字按它增减。
        var fontSize = 12
        /// 差异 / 提交信息等代码文本字号。
        var editorFontSize = 12
        /// 差异每行在字体自然行高之外的额外间距（pt），越小一屏显示行数越多。
        var diffLineSpacing = 2
    }

    struct CommandLog: Codable, Equatable, Sendable {
        /// 每个仓库一份 `logs/*.log`，记录 Git 命令与耗时。
        var enabled = true
        /// 超出后轮转为 `.log.1`，只保留一份旧文件。
        var maxFileMiB = 5
    }

    var appearance = Appearance()
    var editor = Editor()
    var fileManager = FileBrowser()
    var terminal = Terminal()
    var git = Git()
    var commit = Commit()
    var pull = Pull()
    var history = History()
    var diff = Diff()
    var refresh = Refresh()
    var tabs = Tabs()
    var commandLog = CommandLog()
    /// 工具栏「自定义操作」菜单项，按数组顺序显示。
    var customActions: [CustomAction] = []

    func normalized() -> AppConfig {
        var value = self
        value.appearance.fontFamily = appearance.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        value.appearance.monospaceFontFamily = appearance.monospaceFontFamily
            .trimmingCharacters(in: .whitespacesAndNewlines)
        value.appearance.fontSize = appearance.fontSize.clamped(9...20)
        value.appearance.editorFontSize = appearance.editorFontSize.clamped(9...20)
        value.appearance.diffLineSpacing = appearance.diffLineSpacing.clamped(0...20)
        value.editor.path = editor.path.trimmingCharacters(in: .whitespacesAndNewlines)
        value.editor.bundleID = editor.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fileManager.bundleID = fileManager.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        value.terminal.bundleIDs = terminal.bundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        value.git.executable = git.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        value.git.timeoutSeconds = git.timeoutSeconds.clamped(1...3600)
        value.git.commitTimeoutSeconds = git.commitTimeoutSeconds.clamped(1...3600)
        value.git.networkTimeoutSeconds = git.networkTimeoutSeconds.clamped(1...3600)
        value.git.outputLimitMiB = git.outputLimitMiB.clamped(1...512)
        value.commit.defaultMessage = commit.defaultMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        value.history.initialCount = history.initialCount.clamped(50...100_000)
        value.history.pageSize = history.pageSize.clamped(50...100_000)
        value.diff.contextLines = diff.contextLines.clamped(1...20)
        value.diff.previewTimeoutMilliseconds = diff.previewTimeoutMilliseconds.clamped(100...30000)
        value.refresh.pollSeconds = refresh.pollSeconds.clamped(1...600)
        value.refresh.autoFetchSeconds = refresh.autoFetchSeconds.clamped(0...3600)
        value.tabs.idleUnloadSeconds = tabs.idleUnloadSeconds.clamped(1...86400)
        value.tabs.recentCount = tabs.recentCount.clamped(1...100)
        value.commandLog.maxFileMiB = commandLog.maxFileMiB.clamped(1...100)
        // 归一化后 name 为空 = name 与 executable 均为空，没有可执行内容。
        value.customActions = customActions.map { $0.normalized() }.filter { !$0.name.isEmpty }
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
