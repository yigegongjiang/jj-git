import AppKit
import Foundation
import Observation

@MainActor @Observable
final class RepositorySession: Identifiable {
    nonisolated let location: RepositoryLocation
    nonisolated var id: String {
        location.root
    }

    let command: RepositoryCommand
    var status = WorkingCopyStatus()
    var references: [GitReference] = []
    var remotes: [GitRemote] = []
    var worktrees: [GitWorktree] = []
    var graph: [CommitGraphRow] = []
    /// 提交图列宽（轨道数），超过上限的轨道被裁剪，保证提交标题对齐。
    var graphLanes = 1
    var historyLimit = AppConfig.current.history.initialCount
    var hasMoreHistory = false
    var selectedCommit: GitCommit?
    var commitDetail: CommitDetail?
    var selectedCommitFile: CommitFile?
    var selectedFile: FileChange?
    var selectedStaged = false
    var diff: TextDiff?
    var fileDiffs: [FileDiff] = []
    /// true = 全部差异（首次进入 / 手动触发）；选中单个文件后为 false，刷新时只读取该文件。
    var diffOverview = true
    var diffFallback = false
    /// 文件行定位按钮的请求；其他导航清除，避免差异视图重建后重放。
    var diffReveal: DiffReveal?
    var selectedLines: Set<Int> = []
    var message = AppConfig.current.commit.defaultMessage
    var amend = false
    var section = RepositorySection.changes
    var error: String?
    var notice = ""
    /// 最近一次操作的完整输出，点击状态栏提示查看。
    var operationOutput = ""
    var operation: String?
    var operationAction: RepositoryAction?
    /// stderr 最新一行：`--progress` 进度或 hooks 输出。
    var operationProgress: String?
    var operationStarted: Date?
    var refreshing = false
    var loadingDiff = false
    var lastRefreshed: Date?
    var interruptedOperation: String?

    @ObservationIgnored private var active = false
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var monitor: RepositoryMonitor?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored var diffTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var referenceKey = ""
    @ObservationIgnored var diffGeneration = 0
    @ObservationIgnored var revealCount = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var refreshFailure: String?
    /// 打开 / 切换到仓库后首次刷新：无本地变更则显示提交历史；手动切换分区即取消。
    @ObservationIgnored private var sectionAutoPending = false

    init(location: RepositoryLocation) {
        self.location = location
        command = RepositoryCommand(location: location)
    }

    deinit {
        polling?.cancel()
        refreshTask?.cancel()
        detailTask?.cancel()
        diffTask?.cancel()
        operationTask?.cancel()
    }

    func activate() {
        guard !active else { return }
        active = true
        sectionAutoPending = true
        monitor = RepositoryMonitor(location: location) { [weak self] in
            Task { @MainActor [weak self] in self?.filesystemChanged() }
        }
        // FSEvents 负责实时刷新；轮询只兜底漏报，且仅在 App 位于前台时执行。
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(AppConfig.current.refresh.pollSeconds)) } catch { return }
                if NSApplication.shared.isActive {
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    private func filesystemChanged() {
        if active {
            refresh()
        }
    }

    func deactivate() {
        active = false
        monitor = nil
        polling?.cancel()
        polling = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        refreshing = false
    }

    func waitForOperation() async {
        await operationTask?.value
    }

    /// 关闭 / 闲置释放前取消读取任务，避免任务继续持有 session。
    func dispose() {
        deactivate()
        detailTask?.cancel()
        detailTask = nil
        diffTask?.cancel()
        diffTask = nil
    }

    func refresh(forceHistory: Bool = false) {
        if forceHistory {
            referenceKey = ""
        }
        guard operation == nil, !refreshing else { refreshPending = true; return }
        refreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == refreshGeneration {
                    refreshing = false
                    if refreshPending, active {
                        refreshPending = false
                        refresh()
                    }
                }
            }
            do {
                try await refreshSnapshot()
                refreshFailure = nil
            } catch is CancellationError {
                return
            } catch {
                // 同一错误只提示一次，避免每次轮询重新弹出已关闭的提示。
                let message = error.localizedDescription
                if message != refreshFailure {
                    refreshFailure = message
                    self.error = message
                }
            }
        }
    }

    private func refreshSnapshot() async throws {
        let query = command.query
        async let newStatus = query.status()
        async let newRefs = query.references()
        async let newRemotes = query.remotes()
        async let newTrees = query.worktrees()
        let values = try await (newStatus, newRefs, newRemotes, newTrees)
        try Task.checkCancellation()
        let key = values.0.head + values.1.map { $0.fullName + $0.target }.joined()
        let changed = status != values.0
        status = values.0
        references = values.1
        remotes = values.2
        worktrees = values.3
        interruptedOperation = query.operationInProgress()
        if key != referenceKey {
            let commits = try await query.commits(limit: historyLimit, includeHead: !values.0.unborn)
            try Task.checkCancellation()
            graph = CommitGraphRow.build(commits, head: values.0.head)
            graphLanes = min(graph.map(\.width).max() ?? 1, 8)
            hasMoreHistory = commits.count == historyLimit
            referenceKey = key
            if let selectedCommit, !commits.contains(where: { $0.id == selectedCommit.id }) {
                selectCommit(nil)
            }
        }
        lastRefreshed = Date()
        if sectionAutoPending {
            sectionAutoPending = false
            if section == .changes, status.changes.isEmpty, !graph.isEmpty {
                changeSection(.history)
            }
        }
        if section == .changes {
            if changed {
                selectedLines = []
            }
            refreshChangesDiff()
        }
    }
}

extension RepositorySession {
    func changeSection(_ section: RepositorySection) {
        sectionAutoPending = false
        self.section = section
        fileDiffs = []
        diff = nil
        if section == .changes {
            detailTask?.cancel()
            selectChanges(staged: false)
        } else {
            selectCommit(selectedCommit ?? graph.first?.commit)
        }
    }

    func reloadSelectedDiff() {
        loadFileDiff(clearSelection: false)
    }

    private func loadFileDiff(clearSelection: Bool) {
        diffTask?.cancel()
        diffGeneration += 1
        let generation = diffGeneration
        guard let selectedFile else { loadingDiff = false; return }
        let staged = selectedStaged
        if clearSelection {
            selectedLines = []
        }
        loadingDiff = diff == nil
        let previous = diff
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await command.query.diff(selectedFile, staged: staged, reusing: previous)
                try Task.checkCancellation()
                guard generation == diffGeneration else { return }
                if diff?.raw != result.raw {
                    selectedLines = []; diff = result
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
            if generation == diffGeneration {
                loadingDiff = false
            }
        }
    }

    func selectCommit(_ commit: GitCommit?) {
        detailTask?.cancel()
        diffTask?.cancel()
        diffGeneration += 1
        selectedCommit = commit
        fileDiffs = []
        diffFallback = false
        diffReveal = nil
        loadingDiff = false
        commitDetail = nil
        selectedCommitFile = nil
        diff = nil
        guard let commit else { return }
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await command.query.detail(commit)
                try Task.checkCancellation()
                guard selectedCommit?.id == commit.id else { return }
                commitDetail = detail
                showCommitOverview()
            } catch is CancellationError { return } catch { self.error = error.localizedDescription }
        }
    }

    func perform(_ action: RepositoryAction, title: String, completion: (@MainActor () -> Void)? = nil) {
        guard operation == nil else { return }
        operation = title
        operationAction = action
        let started = Date()
        operationStarted = started
        error = nil
        notice = ""
        operationOutput = ""
        refreshTask?.cancel()
        refreshGeneration += 1
        refreshing = false
        // 计时器回调可能晚于操作结束到达；开始时间即本次操作的标识。
        let progress: GitProgressHandler = { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self, operationStarted == started else { return }
                operationProgress = line
            }
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await command.perform(action, progress: progress)
                notice = "\(title)完成 · " + Self.duration(Date().timeIntervalSince(started))
                operationOutput = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
            } catch is CancellationError {
                notice = "操作已取消；正在重新读取仓库状态。"
            } catch {
                self.error = error.localizedDescription
            }
            operation = nil
            operationAction = nil
            operationProgress = nil
            operationStarted = nil
            refreshing = false
            refresh(forceHistory: true)
            if error == nil, !Task.isCancelled {
                completion?()
            }
        }
    }

    /// 0.4s / 12s / 2m05s
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return seconds < 10 ? String(format: "%.1fs", seconds)
            : total < 60 ? "\(total)s" : String(format: "%dm%02ds", total / 60, total % 60)
    }

    /// 上游所在远程，其次 origin，最后第一个远程。
    var defaultRemote: String {
        remotes.first { status.upstream.hasPrefix($0.name + "/") }?.name
            ?? remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name ?? ""
    }

    /// 远端分支对应的本地分支：优先跟踪它的分支，其次同名分支。
    func localBranch(for remoteBranch: GitReference) -> GitReference? {
        let locals = references.filter { !$0.remote && !$0.tag }
        if let tracking = locals.first(where: { $0.upstream == remoteBranch.name }) {
            return tracking
        }
        guard let remote = remotes.filter({ remoteBranch.name.hasPrefix($0.name + "/") })
            .max(by: { $0.name.count < $1.name.count }) else { return nil }
        let name = String(remoteBranch.name.dropFirst(remote.name.count + 1))
        return locals.first { $0.name == name }
    }

    func checkout(_ branch: GitReference) {
        let target = branch.remote ? localBranch(for: branch) ?? branch : branch
        guard !target.current else { return }
        guard target.checkedOutPath.isEmpty else {
            error = "\(target.name) 已在其他工作树检出：\(target.checkedOutPath)"
            return
        }
        perform(.checkout(target), title: "检出 \(target.name)")
    }

    func fetch() {
        let remote = defaultRemote
        guard !remote.isEmpty else { return }
        perform(.fetch(remote: remote), title: "Fetch \(remote)")
    }

    /// 直接推送当前分支到上游（无上游时推送到默认远程的同名分支并建立跟踪）。
    func pushToUpstream() {
        let remote = defaultRemote
        guard !remote.isEmpty, !status.detached, !status.unborn else { return }
        let branch = status.upstream.hasPrefix(remote + "/")
            ? String(status.upstream.dropFirst(remote.count + 1)) : status.branch
        perform(.push(remote: remote, branch: branch, lease: nil), title: "Push")
    }

    func cancelOperation() {
        operationTask?.cancel()
    }
}

enum RepositorySection: String, CaseIterable, Identifiable {
    case history = "提交历史"
    case changes = "本地变更"
    nonisolated var id: String {
        rawValue
    }
}
