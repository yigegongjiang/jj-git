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
    var refreshError: String?
    var fetchError: String?
    var readError: String?
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
    var interruptedOperation: String?

    @ObservationIgnored private(set) var active = false
    @ObservationIgnored var lastRefreshed: ContinuousClock.Instant?
    /// 进行中 / 排队中的刷新范围；操作期间的请求合并为一次，操作结束后与操作自身的刷新一起执行。
    @ObservationIgnored var refreshingScope: RefreshScope = []
    @ObservationIgnored var pendingRefresh: RefreshScope?
    /// 最近一次操作的阶段计时，随其后的刷新完成写入命令记录。
    @ObservationIgnored var operationTrace: OperationTrace?
    @ObservationIgnored private var monitor: RepositoryMonitor?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var autoFetching: Task<Void, Never>?
    /// 进行中的单次自动 Fetch；与之冲突的手动操作等待它结束，同一远程的手动 Fetch 直接沿用其结果。
    @ObservationIgnored var autoFetchRun: AutoFetchRun?
    @ObservationIgnored var fetchFailure: String?
    @ObservationIgnored var fetchFailureRemote: String?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored var detailFailed = false
    @ObservationIgnored var diffTask: Task<Void, Never>?
    @ObservationIgnored var commitCache = CommitDiffCache()
    @ObservationIgnored var overviewTrace: OperationTrace?
    /// 自上次完整读取全部差异以来变化的工作区路径 → 事件序号；`diffsInvalidated` 为全部失效时的序号。
    @ObservationIgnored var changedPaths: [String: Int] = [:]
    @ObservationIgnored var diffsInvalidated: Int? = 0
    @ObservationIgnored var changeSequence = 0
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored var referenceKey = ""
    @ObservationIgnored var diffGeneration = 0
    @ObservationIgnored var revealCount = 0
    @ObservationIgnored var refreshGeneration = 0
    @ObservationIgnored var refreshFailure: String?
    /// 打开 / 切换到仓库后首次刷新：无本地变更则显示提交历史；手动切换分区即取消。
    @ObservationIgnored var sectionAutoPending = false

    init(location: RepositoryLocation) {
        self.location = location
        command = RepositoryCommand(location: location)
    }

    deinit {
        polling?.cancel()
        autoFetching?.cancel()
        refreshTask?.cancel()
        detailTask?.cancel()
        diffTask?.cancel()
        operationTask?.cancel()
    }

    func activate() {
        guard !active else { return }
        active = true
        sectionAutoPending = true
        let location = location
        monitor = RepositoryMonitor(location: location) { [weak self] paths in
            let change = FileSystemChange(paths, in: location)
            guard let scope = change.scope else { return }
            let changed = change.paths
            Task { @MainActor [weak self] in self?.filesystemChanged(scope, paths: changed) }
        }
        // FSEvents 负责实时刷新；轮询只兜底漏报，且仅在 App 位于前台、一个间隔内没有刷新过时执行。
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let interval = Duration.seconds(AppConfig.current.refresh.pollSeconds)
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                if NSApplication.shared.isActive, lastRefreshed.map({ $0.duration(to: .now) >= interval }) ?? true {
                    refresh()
                }
            }
        }
        autoFetching = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = AppConfig.current.refresh.autoFetchSeconds
                // 关闭时仍低频循环，配置改回非 0 后无需重新激活标签。
                do { try await Task.sleep(for: .seconds(seconds == 0 ? 60 : seconds)) } catch { return }
                if seconds > 0 {
                    await self?.autoFetch()
                }
            }
        }
        refresh([.references, .contents])
    }

    private func filesystemChanged(_ scope: RefreshScope, paths: [String]) {
        guard active else { return }
        markChanged(paths)
        refresh(scope)
    }

    func deactivate() {
        active = false
        monitor = nil
        polling?.cancel()
        polling = nil
        autoFetching?.cancel()
        autoFetching = nil
        cancelRefresh()
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
        commitCache = CommitDiffCache()
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
                readError = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == diffGeneration else { return }
                readError = error.localizedDescription
            }
            if generation == diffGeneration {
                loadingDiff = false
            }
        }
    }

    func selectCommit(_ commit: GitCommit?) {
        if selectedCommit?.id != commit?.id {
            readError = nil
        }
        detailFailed = false
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
        if let cached = commitCache.entry(for: commit) {
            commitDetail = cached.detail
            readError = nil
            return showCommitOverview()
        }
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await command.query.detail(commit)
                try Task.checkCancellation()
                guard selectedCommit?.id == commit.id else { return }
                commitDetail = detail
                readError = nil
                showCommitOverview()
            } catch is CancellationError { return } catch {
                guard !Task.isCancelled, selectedCommit?.id == commit.id else { return }
                detailFailed = true
                readError = error.localizedDescription
            }
        }
    }

    func perform(_ action: RepositoryAction, title: String, completion: (@MainActor () -> Void)? = nil) {
        guard operation == nil else { return }
        let clicked = ContinuousClock.now
        operation = title
        operationAction = action
        let started = Date()
        operationStarted = started
        error = nil
        notice = ""
        operationOutput = ""
        cancelRefresh()
        // 计时器回调可能晚于操作结束到达；开始时间即本次操作的标识。
        let progress: GitProgressHandler = { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self, operationStarted == started else { return }
                operationProgress = line
            }
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            var trace = OperationTrace(name: title, start: clicked)
            do {
                let output = try await execute(action, progress: progress, trace: &trace)
                trace.mark("git")
                succeeded = true
                notice = "\(title)完成 · " + Self.duration(Date().timeIntervalSince(started))
                operationOutput = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
                if case let .fetch(remote) = action {
                    clearFetchError(remote: remote)
                }
            } catch is CancellationError {
                notice = "操作已取消；正在重新读取仓库状态。"
            } catch {
                trace.mark("git")
                if case let .fetch(remote) = action {
                    reportFetchFailure(remote: remote, failure: error, automatic: false)
                } else {
                    self.error = error.localizedDescription
                }
            }
            operation = nil
            operationAction = nil
            operationProgress = nil
            operationStarted = nil
            operationTrace = trace
            markChanged(action.writtenPaths)
            refresh(action.refreshScope)
            if succeeded, !Task.isCancelled {
                completion?()
            }
        }
    }

    /// 自动 Fetch 进行中时：同一远程的 Fetch 直接沿用其结果；与 Fetch 冲突的操作等待它结束（通常 < 3s）；
    /// 本地操作立即执行。用户取消等待时才终止自动 Fetch（终止可能残留 ref `.lock`）。
    private func execute(_ action: RepositoryAction, progress: @escaping GitProgressHandler,
                         trace: inout OperationTrace) async throws -> String {
        if let fetch = autoFetchRun {
            let joins = if case let .fetch(remote) = action {
                remote == fetch.remote
            } else {
                false
            }
            if joins || !action.lane.runs(alongside: .fetch) {
                if !joins {
                    operationProgress = "等待自动 Fetch 结束"
                }
                let result = await withTaskCancellationHandler { await fetch.task.value } onCancel: {
                    fetch.task.cancel()
                }
                try Task.checkCancellation()
                trace.mark(joins ? "joined" : "wait")
                if joins {
                    return try result.get()
                }
                operationProgress = nil
            }
        }
        return try await command.perform(action, progress: progress)
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
